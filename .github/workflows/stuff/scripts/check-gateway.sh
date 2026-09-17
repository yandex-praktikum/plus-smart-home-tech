#!/bin/bash

# Проверка того, что в решении есть API Gateway и что он балансирует нагрузку
# через реестр сервисов (этап 10-gateway-load-balancing и последующие).
#
# Проверяется по исходникам:
#   1. модуль gateway существует и назван так, как его умеет запускать start-services.sh;
#   2. подключён spring-cloud-starter-gateway;
#   3. gateway — клиент Eureka: без реестра балансировать не между чем;
#   4. маршруты ведут на lb://<имя-сервиса>, а не на фиксированный host:port;
#   5. маршрутами покрыты все сервисы магазина;
#   6. мягко: ретраи для GET-запросов и таймауты.
#
# Поведение под нагрузкой (распределение запросов между экземплярами и отказ
# одного из них) проверяется postman-тестами через run-gateway-tests.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./config-lib.sh
source "${SCRIPT_DIR}/config-lib.sh"

ERRORS=0

fail() {
  cfg_err "$*"
  ERRORS=$((ERRORS + 1))
}

# Имена модуля gateway, которые умеет запускать start-services.sh.
# Если модуль назван иначе, пайплайн не найдёт JAR — это ошибка, а не предупреждение.
GATEWAY_MODULE_NAMES=${GATEWAY_MODULE_NAMES:-"gateway-server api-gateway gateway"}

# Сервисы магазина, которые обязаны быть доступны через gateway
SHOP_SERVICES=${SHOP_SERVICES:-"product-service inventory-service order-service"}

# Порт, на который ходят postman-тесты этапа
GATEWAY_PORT=${GATEWAY_PORT:-8080}

echo "🚪 Проверка API Gateway (ветка: ${BRANCH_NAME:-${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}})"

# --------------------------------------------------------------------------------------
# 1. Модуль gateway
# --------------------------------------------------------------------------------------

echo ""
echo "=== 1. Проверка модуля gateway ==="

GATEWAY_DIR=""
GATEWAY_MODULE=""

for name in $GATEWAY_MODULE_NAMES; do
  dir=$(cfg_module_dir_by_name "$name" 2>/dev/null) || continue
  [ -n "$dir" ] || continue
  # Каталоги-остатки от других веток содержат только target/ — это не модуль
  [ -d "$dir/src/main" ] || continue

  GATEWAY_DIR="$dir"
  GATEWAY_MODULE="$name"
  break
done

if [ -z "$GATEWAY_DIR" ]; then
  fail "Не найден модуль gateway. Он должен называться одним из: ${GATEWAY_MODULE_NAMES}"
  cfg_err "Проверка API Gateway завершилась с ошибками: $ERRORS"
  exit 1
fi

GATEWAY_APP=$(cfg_module_app_name "$GATEWAY_DIR")
cfg_ok "Модуль gateway: $GATEWAY_DIR (spring.application.name = $GATEWAY_APP)"

if ! cfg_module_has_dependency "$GATEWAY_DIR" "spring-cloud-starter-gateway"; then
  fail "В модуле $GATEWAY_MODULE не подключён spring-cloud-starter-gateway"
else
  cfg_ok "Подключён spring-cloud-starter-gateway"
fi

if cfg_module_has_dependency "$GATEWAY_DIR" "spring-cloud-starter-netflix-eureka-client"; then
  cfg_ok "Gateway зарегистрирован в Eureka и знает об экземплярах сервисов"
else
  fail "В модуле $GATEWAY_MODULE не подключён spring-cloud-starter-netflix-eureka-client:
   без реестра gateway не сможет найти экземпляры сервисов и балансировать между ними"
fi

# --------------------------------------------------------------------------------------
# 2. Конфигурация gateway
# --------------------------------------------------------------------------------------

echo ""
echo "=== 2. Поиск конфигурации gateway ==="

# Конфигурация может лежать и в самом модуле, и в репозитории config-server:
# ищем и там, и там — по имени приложения.
gateway_config_files() {
  {
    cfg_module_config_files "$GATEWAY_DIR"

    find "$ROOT_DIR" \
      \( -name "${GATEWAY_APP}.yml" -o -name "${GATEWAY_APP}.yaml" -o -name "${GATEWAY_APP}.properties" \) \
      -not -path "*/target/*" -not -path "*/.git/*" 2>/dev/null
  } | sort -u
}

CONFIG_FILES=$(gateway_config_files)
mapfile -t CONFIG_FILE_LIST <<< "$CONFIG_FILES"

if [ -z "$CONFIG_FILES" ]; then
  fail "Не найдено ни одного файла конфигурации gateway (ни в модуле, ни в репозитории config-server)"
  cfg_err "Проверка API Gateway завершилась с ошибками: $ERRORS"
  exit 1
fi

while IFS= read -r file; do
  [ -n "$file" ] && cfg_info "   • $file"
done <<< "$CONFIG_FILES"

# Порт gateway: postman-тесты этапа ходят на фиксированный адрес
GATEWAY_CONFIGURED_PORT=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  value=$(cfg_get "$file" "server.port")
  if [ -n "$value" ]; then
    GATEWAY_CONFIGURED_PORT="$value"
    break
  fi
done <<< "$CONFIG_FILES"

if [ -z "$GATEWAY_CONFIGURED_PORT" ]; then
  cfg_warn "В конфигурации gateway не задан server.port — тесты ожидают его на порту ${GATEWAY_PORT}"
elif [ "$GATEWAY_CONFIGURED_PORT" != "$GATEWAY_PORT" ]; then
  fail "Gateway настроен на порт ${GATEWAY_CONFIGURED_PORT}, а тесты этапа ходят на ${GATEWAY_PORT}:
   gateway — единственная публичная точка входа, его адрес должен быть фиксированным"
else
  cfg_ok "Gateway слушает порт ${GATEWAY_PORT}"
fi

# --------------------------------------------------------------------------------------
# 3. Маршруты и балансировка
# --------------------------------------------------------------------------------------

echo ""
echo "=== 3. Проверка маршрутов ==="

# Балансировка включается схемой lb://: gateway берёт список экземпляров сервиса
# из реестра и распределяет между ними запросы.
LB_TARGETS=$(grep -hoE 'lb://[A-Za-z0-9_.-]+' "${CONFIG_FILE_LIST[@]}" 2>/dev/null | sed 's|lb://||' | sort -u)

# Маршруты на фиксированный адрес означают, что балансировки нет:
# все запросы уходят на один-единственный экземпляр.
HARDCODED=$(grep -hnE '^[[:space:]]*-?[[:space:]]*uri:[[:space:]]*"?http' "${CONFIG_FILE_LIST[@]}" 2>/dev/null | sort -u)

DISCOVERY_LOCATOR=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  value=$(cfg_get "$file" "spring.cloud.gateway.discovery.locator.enabled")
  [ "$value" = "true" ] && DISCOVERY_LOCATOR="$file"
done <<< "$CONFIG_FILES"

if [ -n "$LB_TARGETS" ]; then
  cfg_ok "Маршруты ведут на сервисы через балансировщик: $(echo "$LB_TARGETS" | tr '\n' ' ')"
elif [ -n "$DISCOVERY_LOCATOR" ]; then
  cfg_warn "Явных маршрутов lb:// нет, включён discovery.locator ($DISCOVERY_LOCATOR).
   Маршруты будут вида /ИМЯ-СЕРВИСА/**, а тесты этапа ходят по /api/**"
else
  fail "В конфигурации gateway нет ни одного маршрута с uri: lb://<имя-сервиса>.
   Именно схема lb:// включает балансировку между экземплярами сервиса"
fi

if [ -n "$HARDCODED" ]; then
  fail "Маршруты ведут на фиксированный адрес, а не на имя сервиса в реестре —
   балансировать между экземплярами в этом случае не получится:"
  echo "$HARDCODED" | sed 's/^/   /'
fi

# Каждый сервис магазина должен быть доступен снаружи через gateway
if [ -n "$LB_TARGETS" ]; then
  MISSING=""
  for service in $SHOP_SERVICES; do
    if ! grep -qix "$service" <<< "$LB_TARGETS"; then
      MISSING="${MISSING} ${service}"
    fi
  done

  if [ -n "$MISSING" ]; then
    if [ -n "$DISCOVERY_LOCATOR" ]; then
      cfg_warn "Нет явных маршрутов для:${MISSING} (возможно, их заменяет discovery.locator)"
    else
      fail "Нет маршрутов для сервисов:${MISSING} — снаружи они будут недоступны"
    fi
  else
    cfg_ok "Маршрутами покрыты все сервисы магазина: $SHOP_SERVICES"
  fi
fi

# --------------------------------------------------------------------------------------
# 4. Устойчивость маршрутов (мягкие проверки)
# --------------------------------------------------------------------------------------

echo ""
echo "=== 4. Проверка настроек устойчивости ==="

if grep -hqE '(^|[^A-Za-z])Retry([^A-Za-z]|$)' "${CONFIG_FILE_LIST[@]}" 2>/dev/null; then
  cfg_ok "Настроен фильтр Retry: запрос к упавшему экземпляру будет повторён на живом"
else
  cfg_warn "Фильтр Retry не найден. Без него запрос, попавший на только что упавший экземпляр,
   вернёт клиенту ошибку вместо повторной попытки на другом экземпляре"
fi

if grep -hqE 'connect-timeout|response-timeout' "${CONFIG_FILE_LIST[@]}" 2>/dev/null; then
  cfg_ok "Заданы таймауты обращения gateway к сервисам"
else
  cfg_warn "Таймауты обращения к сервисам не заданы — будут использованы значения по умолчанию"
fi

echo ""
if [ "$ERRORS" -ne 0 ]; then
  cfg_err "Проверка API Gateway завершилась с ошибками: $ERRORS"
  exit 1
fi

cfg_ok "Проверка API Gateway пройдена"
exit 0
