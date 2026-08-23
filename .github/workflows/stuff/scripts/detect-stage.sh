#!/bin/bash

# Определяет "этап" решения — набор сервисов, которые нужно запустить и протестировать.
#
# Для веток заданий этап однозначно определяется именем ветки.
# Для интеграционных веток (develop, development) имя ветки ничего не говорит об их
# содержимом, поэтому этап определяется по коду решения.
#
# Важно: заготовки модулей из precode (каталог, pom.xml и класс с @SpringBootApplication,
# но без контроллеров, сущностей, сервисов и конфигураций) реализацией не считаются.
# Иначе ветка develop, в которую влит только этап 4-analyzer, определялась бы как этап 7
# (в precode уже лежат пустые модули commerce) и падала бы на проверках config-server.
#
# Результат печатается в stdout, диагностика — в stderr.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./config-lib.sh
source "${SCRIPT_DIR}/config-lib.sh"

BRANCH_NAME=${BRANCH_NAME:-${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}}

if [ -z "$BRANCH_NAME" ]; then
  echo "❌ Ошибка: Не удалось определить ветку." >&2
  exit 1
fi

# Ветки, в которые вливаются задания: их содержимое определяем по коду, а не по имени.
INTEGRATION_BRANCHES=${INTEGRATION_BRANCHES:-"develop development"}

log() {
  echo "$@" >&2
}

# --------------------------------------------------------------------------------------
# Поиск признаков решения в исходниках
# --------------------------------------------------------------------------------------

# Каталоги модуля: ищем и по имени каталога, и по artifactId в pom.xml,
# чтобы не зависеть от того, как студент разложил модули по проекту.
service_dirs() {
  local name=$1

  {
    find "$ROOT_DIR" -type d -name "$name" \
      -not -path "*/target/*" -not -path "*/.git/*" 2>/dev/null || true

    find "$ROOT_DIR" -name pom.xml \
      -not -path "*/target/*" -not -path "*/.git/*" \
      -exec grep -l "<artifactId>${name}</artifactId>" {} + 2>/dev/null \
      | while IFS= read -r pom; do dirname "$pom"; done || true
  } | sort -u
}

# Сервис считается реализованным, если в его модуле есть Spring Boot приложение
# и собственный код (контроллеры, сущности, сервисы, конфигурации), а не только
# заготовка из precode.
has_service() {
  local name=$1
  local dir

  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    [ -d "$dir/src/main" ] || continue
    grep -rq --include="*.java" --include="*.kt" "@SpringBootApplication" "$dir/src/main" 2>/dev/null || continue

    if cfg_module_has_implementation "$dir"; then
      log "   ✔ $name: $dir"
      return 0
    fi

    log "   • $name: $dir — только заготовка модуля, реализации нет"
  done <<< "$(service_dirs "$name")"

  return 1
}

# Возвращает 0, только если реализованы все перечисленные сервисы.
has_all_services() {
  local missing=()
  local service

  for service in "$@"; do
    if ! has_service "$service"; then
      missing+=("$service")
    fi
  done

  if [ ${#missing[@]} -ne 0 ]; then
    log "   ✖ не реализованы сервисы: ${missing[*]}"
    return 1
  fi

  return 0
}

has_pom_marker() {
  grep -rqE --include="pom.xml" --exclude-dir=target --exclude-dir=.git \
    "$1" "$ROOT_DIR" 2>/dev/null
}

has_source_marker() {
  grep -rqE --include="*.java" --include="*.kt" --exclude-dir=target --exclude-dir=.git \
    "$1" "$ROOT_DIR" 2>/dev/null
}

has_config_server() {
  [ -n "$(cfg_config_server_dir 2>/dev/null)" ]
}

has_discovery_server() {
  has_source_marker "@EnableEurekaServer" \
    || has_pom_marker "<artifactId>spring-cloud-starter-netflix-eureka-server</artifactId>"
}

has_gateway() {
  local module

  has_pom_marker "<artifactId>spring-cloud-starter-gateway[^<]*</artifactId>" || return 1

  # Считаем этап gateway'ным, только если модуль называется так, как его умеет
  # запускать start-services.sh, — иначе пайплайн упадёт на поиске JAR-файла.
  for module in gateway-server api-gateway gateway; do
    if [ -n "$(cfg_module_dir_by_name "$module" 2>/dev/null)" ]; then
      return 0
    fi
  done

  return 1
}

has_feign() {
  has_pom_marker "<artifactId>spring-cloud-starter-openfeign</artifactId>" \
    || has_source_marker "@FeignClient"
}

has_circuit_breaker() {
  has_pom_marker "<artifactId>(spring-cloud-starter-circuitbreaker[^<]*|resilience4j-spring-boot[0-9]*)</artifactId>" \
    || has_source_marker "@CircuitBreaker"
}

has_security() {
  has_pom_marker "<artifactId>spring-(boot-starter-security|boot-starter-oauth2-[^<]*|cloud-starter-security)</artifactId>" \
    || has_source_marker "@EnableWebSecurity|@EnableWebFluxSecurity"
}

# --------------------------------------------------------------------------------------
# Определение этапа по коду решения
# --------------------------------------------------------------------------------------

# Трек микросервисов витрины: 7-spring-cloud-microservices → 8-gateway → 9-gateway-microservices
detect_showcase_stage() {
  if has_all_services "order" "payment" "delivery"; then
    log "🔎 Реализованы сервисы заказа, оплаты и доставки — этап 9-gateway-microservices"
    echo "9-gateway-microservices"
    return 0
  fi

  if has_gateway; then
    log "🔎 Найден API Gateway — этап 8-gateway"
    echo "8-gateway"
    return 0
  fi

  log "🔎 Реализованы микросервисы витрины — этап 7-spring-cloud-microservices"
  echo "7-spring-cloud-microservices"
}

# Трек микросервисов магазина: 7-microservices → 8-open-feign → 9-circuit-breaker
#                              → 10-gateway-load-balancing → 11-security
detect_shop_stage() {
  if has_gateway && has_security; then
    log "🔎 Найдены API Gateway и настройки безопасности — этап 11-security"
    echo "11-security"
    return 0
  fi

  if has_gateway; then
    log "🔎 Найден API Gateway — этап 10-gateway-load-balancing"
    echo "10-gateway-load-balancing"
    return 0
  fi

  if has_circuit_breaker; then
    log "🔎 Найдена реализация Circuit Breaker — этап 9-circuit-breaker"
    echo "9-circuit-breaker"
    return 0
  fi

  if has_feign; then
    log "🔎 Найдены Feign-клиенты — этап 8-open-feign"
    echo "8-open-feign"
    return 0
  fi

  log "🔎 Реализованы микросервисы магазина — этап 7-microservices"
  echo "7-microservices"
}

detect_stage_by_code() {
  if has_all_services "shopping-store" "shopping-cart" "warehouse"; then
    detect_showcase_stage
    return 0
  fi

  if has_all_services "product-service" "order-service" "inventory-service"; then
    detect_shop_stage
    return 0
  fi

  if has_discovery_server; then
    log "🔎 Микросервисов нет, найден discovery-server — этап 6-discovery-server"
    echo "6-discovery-server"
    return 0
  fi

  if has_config_server; then
    log "🔎 Микросервисов нет, найден config-server — этап 5-config-server"
    echo "5-config-server"
    return 0
  fi

  log "🔎 Ни микросервисов, ни инфраструктуры Spring Cloud не найдено —"
  log "   в решении только телеметрия (этап 4-analyzer)"
  echo "develop"
}

case " $INTEGRATION_BRANCHES " in
  *" $BRANCH_NAME "*)
    log "🔎 Ветка $BRANCH_NAME: определяем этап по коду решения..."
    detect_stage_by_code
    ;;
  *)
    log "🔎 Ветка $BRANCH_NAME: этап определяется именем ветки"
    echo "$BRANCH_NAME"
    ;;
esac
