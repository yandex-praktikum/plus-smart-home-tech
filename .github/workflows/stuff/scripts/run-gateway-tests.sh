#!/bin/bash

# Проверка API Gateway и балансировки нагрузки (этап 10-gateway-load-balancing).
#
# Все запросы тестов идут через gateway: сервисы магазина подняты на случайных
# портах (server.port: 0), и снаружи известен только адрес gateway.
#
# Фазы:
#   1. routing        — каждый сервис доступен по своему маршруту, лишние пути отклоняются;
#   2. baseline       — полная коллекция этапа через gateway, по одному экземпляру сервиса;
#   3. load-balancing — поднят второй экземпляр product-service: запросы должны
#                       расходиться по обоим экземплярам, а результат от этого не зависеть;
#   4. failover       — второй экземпляр погашен: снаружи отказ виден быть не должен.
#
# Распределение запросов между экземплярами считается по access-логам Tomcat:
# приложение ничего о себе в ответе не сообщает, а свой лог есть у каждого экземпляра.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./service-control.sh
source "${SCRIPT_DIR}/service-control.sh"

if [ -z "$BRANCH_NAME" ]; then
  BRANCH_NAME=${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}
fi

COLLECTIONS_DIR="${STUFF_PATH:-.github/workflows/stuff}/postman/${BRANCH_NAME}"
REPORTS_DIR="${REPORTS_DIR:-./reports}"
TEMPLATE_PATH="${STUFF_PATH:-.github/workflows/stuff}/postman/dashboard-template.hbs"

mkdir -p "$REPORTS_DIR"

GATEWAY_URL=${GATEWAY_URL:-http://localhost:8080}

LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"
ACCESS_LOG_DIR="${ACCESS_LOG_DIR:-$(cd "$LOG_DIR" && pwd)/access}"

# Масштабируем каталог: он читается чаще всего, и именно на нём заметнее всего,
# распределяет gateway нагрузку или всегда ходит на один экземпляр.
SCALED_MODULE=${SCALED_MODULE:-product-service}
REPLICA_SUFFIX=${REPLICA_SUFFIX:-2}
PROBE_PATH=${PROBE_PATH:-/api/products}

# Сколько запросов отправляем, чтобы оценить распределение. Балансировщик по умолчанию
# работает по кругу, поэтому нескольких десятков запросов достаточно с большим запасом.
PROBE_REQUESTS=${PROBE_REQUESTS:-40}

# Сколько ждать, пока gateway узнает о новом экземпляре: реестр у клиентов обновляется
# раз в 5 секунд, столько же живёт кэш списка экземпляров у балансировщика
# (см. DISCOVERY_CLIENT_ARGS и GATEWAY_ARGS в start-services.sh).
LB_REFRESH_WAIT=${LB_REFRESH_WAIT:-25}

# Столько же нужно, чтобы балансировщик забыл о погашенном экземпляре
FAILOVER_WAIT=${FAILOVER_WAIT:-25}

SCALED_APP=$(svc_app_name "$SCALED_MODULE")
[ -n "$SCALED_APP" ] || SCALED_APP="$SCALED_MODULE"

PRIMARY_ACCESS_LOG="${ACCESS_LOG_DIR}/${SCALED_MODULE}.log"
REPLICA_ACCESS_LOG="${ACCESS_LOG_DIR}/$(svc_replica_key "$SCALED_MODULE" "$REPLICA_SUFFIX").log"

# Дополнительный экземпляр не должен пережить скрипт: последующие шаги workflow
# рассчитывают на тот же стенд, что и до тестов.
cleanup() {
  svc_stop_replica "$SCALED_MODULE" "$REPLICA_SUFFIX" || true
}

trap cleanup EXIT

# --------------------------------------------------------------------------------------
# Вспомогательные функции
# --------------------------------------------------------------------------------------

run_collection() {
  local file=$1
  local title=$2

  local path="${COLLECTIONS_DIR}/${file}"

  if [ ! -f "$path" ]; then
    echo "❌ Ошибка: коллекция Postman не найдена: $path"
    exit 1
  fi

  echo ""
  echo "▶️  $title (${file})"

  newman run "$path" \
    --delay-request 50 -r cli,htmlextra \
    --color on --reporter-htmlextra-darkTheme \
    --timeout-script 120000 \
    --reporter-htmlextra-export "${REPORTS_DIR}/${BRANCH_NAME}-${file%.json}.html" \
    --reporter-htmlextra-title "$title" \
    --reporter-htmlextra-logs true \
    --reporter-htmlextra-template "$TEMPLATE_PATH"
}

# Маршруты gateway — только диагностика: в отчёте о падении полезно видеть,
# какие маршруты реально зарегистрировались. Само наличие actuator не обязательно.
print_gateway_routes() {
  local routes

  echo "📡 Маршруты gateway (${GATEWAY_URL}/actuator/gateway/routes):"

  routes=$(curl -s --connect-timeout 5 "${GATEWAY_URL}/actuator/gateway/routes" || true)

  if [ -z "$routes" ]; then
    echo "⚠️  Не удалось получить маршруты — actuator-эндпоинт gateway недоступен"
    return 0
  fi

  if command -v jq > /dev/null 2>&1; then
    echo "$routes" | jq -r '.[]? | "   " + (.route_id // .routeId // "?") + " -> " + (.uri // "?")' 2>/dev/null \
      || echo "$routes"
  else
    echo "$routes"
  fi
}

print_eureka_instances() {
  local app=$1

  command -v jq > /dev/null 2>&1 || return 0

  echo "📋 Экземпляры $app в Eureka:"
  curl -s -H "Accept: application/json" "${EUREKA_URL}/apps/${app}" 2>/dev/null \
    | jq -r '.application.instance // [] | if type=="array" then .[] else . end
             | "   " + (.instanceId // "?") + " порт " + ((.port["$"] // 0) | tostring) + " — " + .status' \
      2>/dev/null || true
}

# Серия одинаковых GET-запросов через gateway. Коды ответов складываем в глобальные
# переменные: у скрипта нет способа вернуть несколько значений иначе.
probe_gateway() {
  local path=$1
  local times=$2
  local i code

  PROBE_OK=0
  PROBE_SERVER_ERRORS=0
  PROBE_CODES=""

  for ((i = 1; i <= times; i++)); do
    # При обрыве соединения curl сам печатает 000 и завершается с ошибкой,
    # поэтому подставлять своё значение нужно только на пустой вывод.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${GATEWAY_URL}${path}" 2>/dev/null || true)
    [ -n "$code" ] || code="000"

    PROBE_CODES="${PROBE_CODES}${code} "

    case "$code" in
      200)     PROBE_OK=$((PROBE_OK + 1)) ;;
      5*|000)  PROBE_SERVER_ERRORS=$((PROBE_SERVER_ERRORS + 1)) ;;
    esac
  done
}

# Сколько запросов к проверяемому пути обработал экземпляр, судя по его access-логу
count_access_requests() {
  local file=$1
  local count

  [ -f "$file" ] || { echo 0; return 0; }

  count=$(grep -c "\"GET ${PROBE_PATH} " "$file" 2>/dev/null) || count=0
  echo "${count:-0}"
}

# --------------------------------------------------------------------------------------
# Фаза 1. Маршрутизация
# --------------------------------------------------------------------------------------

echo "🚪 Проверка API Gateway и балансировки нагрузки (ветка: $BRANCH_NAME)"
echo ""
print_gateway_routes
print_eureka_instances "$SCALED_APP"

run_collection "gateway-routing.json" "Gateway: маршрутизация"

# --------------------------------------------------------------------------------------
# Фаза 2. Полная коллекция этапа через gateway
# --------------------------------------------------------------------------------------

run_collection "postman.json" "Основные тесты API через gateway"

# --------------------------------------------------------------------------------------
# Фаза 3. Балансировка между двумя экземплярами
# --------------------------------------------------------------------------------------

echo ""
echo "=============================================================="
echo " Поднимаем второй экземпляр $SCALED_MODULE — проверяем балансировку"
echo "=============================================================="

svc_start_replica "$SCALED_MODULE" "$REPLICA_SUFFIX"
svc_wait_instances "$SCALED_APP" 2

echo "⏳ Ждём ${LB_REFRESH_WAIT}s: gateway должен получить обновлённый список экземпляров..."
sleep "$LB_REFRESH_WAIT"

print_eureka_instances "$SCALED_APP"

BEFORE_PRIMARY=$(count_access_requests "$PRIMARY_ACCESS_LOG")
BEFORE_REPLICA=$(count_access_requests "$REPLICA_ACCESS_LOG")

echo ""
echo "🔁 Отправляем ${PROBE_REQUESTS} запросов ${PROBE_PATH} через gateway..."
probe_gateway "$PROBE_PATH" "$PROBE_REQUESTS"

echo "   успешных: ${PROBE_OK}/${PROBE_REQUESTS}, ошибок сервера: ${PROBE_SERVER_ERRORS}"

if [ "$PROBE_OK" -ne "$PROBE_REQUESTS" ]; then
  echo "❌ Не все запросы через gateway успешны. Коды ответов: ${PROBE_CODES}"
  exit 1
fi

# Access-лог пишется с buffered=false, но дать Tomcat дописать последние строки стоит
sleep 3

AFTER_PRIMARY=$(count_access_requests "$PRIMARY_ACCESS_LOG")
AFTER_REPLICA=$(count_access_requests "$REPLICA_ACCESS_LOG")

DELTA_PRIMARY=$((AFTER_PRIMARY - BEFORE_PRIMARY))
DELTA_REPLICA=$((AFTER_REPLICA - BEFORE_REPLICA))
DELTA_TOTAL=$((DELTA_PRIMARY + DELTA_REPLICA))

echo ""
echo "📊 Распределение запросов между экземплярами $SCALED_MODULE:"
echo "   экземпляр 1: ${DELTA_PRIMARY} ($PRIMARY_ACCESS_LOG)"
echo "   экземпляр 2: ${DELTA_REPLICA} ($REPLICA_ACCESS_LOG)"

if [ "$DELTA_TOTAL" -eq 0 ]; then
  echo "⚠️  Access-логи экземпляров пусты или недоступны — распределение запросов"
  echo "   проверить не удалось. Балансировка подтверждается только тем, что оба"
  echo "   экземпляра зарегистрированы в Eureka и запросы через gateway успешны."
elif [ "$DELTA_PRIMARY" -eq 0 ] || [ "$DELTA_REPLICA" -eq 0 ]; then
  echo "❌ Все ${DELTA_TOTAL} запросов обработал один экземпляр сервиса."
  echo "   Gateway должен распределять нагрузку между всеми экземплярами из реестра:"
  echo "   проверьте, что маршрут задан как uri: lb://${SCALED_APP}, а не фиксированным адресом."
  exit 1
else
  echo "✅ Запросы распределены между обоими экземплярами"
fi

run_collection "load-balancing.json" "Gateway: балансировка между экземплярами"

# --------------------------------------------------------------------------------------
# Фаза 4. Отказ одного экземпляра
# --------------------------------------------------------------------------------------

echo ""
echo "=============================================================="
echo " Гасим второй экземпляр $SCALED_MODULE — проверяем отказоустойчивость"
echo "=============================================================="

svc_stop_replica "$SCALED_MODULE" "$REPLICA_SUFFIX"

# Сразу после остановки балансировщик какое-то время ещё считает экземпляр живым.
# Именно здесь работает фильтр Retry: повтор запроса уходит на следующий экземпляр,
# и клиент не должен увидеть ошибку.
echo ""
echo "🔁 Сразу после остановки отправляем 20 запросов ${PROBE_PATH} через gateway..."
probe_gateway "$PROBE_PATH" 20

echo "   успешных: ${PROBE_OK}/20, ошибок сервера: ${PROBE_SERVER_ERRORS}"

if [ "$PROBE_SERVER_ERRORS" -ne 0 ]; then
  echo "❌ Отказ одного экземпляра виден снаружи: ${PROBE_SERVER_ERRORS} запросов из 20"
  echo "   завершились ошибкой сервера. Коды ответов: ${PROBE_CODES}"
  echo "   Пока жив хотя бы один экземпляр, gateway должен повторить запрос на нём"
  echo "   (фильтр Retry для GET-маршрутов)."
  exit 1
fi

echo "✅ Отказ экземпляра снаружи не виден"

echo "⏳ Ждём ${FAILOVER_WAIT}s: балансировщик должен забыть о погашенном экземпляре..."
sleep "$FAILOVER_WAIT"

print_eureka_instances "$SCALED_APP"
run_collection "failover.json" "Gateway: отказ одного экземпляра"

echo ""
echo "✅ Проверка API Gateway и балансировки нагрузки завершена"
