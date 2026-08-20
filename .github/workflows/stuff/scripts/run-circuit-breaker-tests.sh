#!/bin/bash

# Проверка паттерна Circuit Breaker под нагрузкой.
#
# Обычные postman-тесты проверяют API при полностью поднятом стенде. Здесь мы
# намеренно гасим зависимости order-service и проверяем, что:
#   * отказ соседнего сервиса не превращается в отказ order-service (нет 5xx);
#   * заказ создаётся в «неподтверждённом» статусе с пояснением причины;
#   * после восстановления зависимости заказы снова подтверждаются, а резерв ставится.
#
# Фазы:
#   1. baseline            — все сервисы подняты (полная коллекция этапа);
#   2. degraded-inventory  — остановлен inventory-service;
#   3. recovery            — inventory-service поднят обратно;
#   4. degraded-product    — остановлен product-service.

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

# Сколько ждать, пока соседи узнают о восстановлении сервиса и закроется circuit breaker.
# Реестр Eureka у клиентов обновляется раз в 5 секунд (см. start-services.sh),
# состояние open у circuit breaker в эталоне держится 10 секунд.
RECOVERY_WAIT=${RECOVERY_WAIT:-30}

INVENTORY_MODULE=${INVENTORY_MODULE:-inventory-service}
PRODUCT_MODULE=${PRODUCT_MODULE:-product-service}

# Что бы ни случилось, стенд надо вернуть в рабочее состояние:
# иначе последующие шаги workflow будут падать по непонятной причине.
restore_services() {
  local module

  for module in "$INVENTORY_MODULE" "$PRODUCT_MODULE"; do
    local pid
    pid=$(svc_pid "$module" 2>/dev/null || true)
    if [ -n "$pid" ] && ! svc_is_running "$pid"; then
      echo "♻️  Восстанавливаем сервис $module после тестов..."
      svc_start "$module" || true
    fi
  done
}

trap restore_services EXIT

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

print_eureka_apps() {
  command -v jq > /dev/null 2>&1 || return 0
  echo "📋 Сервисы в Eureka:"
  curl -s -H "Accept: application/json" "${EUREKA_URL}/apps" \
    | jq -r '.applications.application // [] | if type=="array" then .[] else . end
             | .name + ": " + ([.instance] | flatten | map(.status) | join(", "))' 2>/dev/null || true
}

echo "🚀 Проверка Circuit Breaker для ветки: $BRANCH_NAME"
print_eureka_apps

# --------------------------------------------------------------------------------------
# Фаза 1. Стенд полностью поднят
# --------------------------------------------------------------------------------------

run_collection "postman.json" "Основные тесты API (все сервисы доступны)"

# --------------------------------------------------------------------------------------
# Фаза 2. Недоступен inventory-service
# --------------------------------------------------------------------------------------

echo ""
echo "=============================================================="
echo " Гасим $INVENTORY_MODULE — проверяем деградацию оформления заказа"
echo "=============================================================="

svc_stop "$INVENTORY_MODULE"
sleep 10

run_collection "degraded-inventory.json" "Circuit Breaker: склад недоступен"

# --------------------------------------------------------------------------------------
# Фаза 3. inventory-service восстановлен
# --------------------------------------------------------------------------------------

echo ""
echo "=============================================================="
echo " Поднимаем $INVENTORY_MODULE — проверяем восстановление"
echo "=============================================================="

svc_start "$INVENTORY_MODULE"
svc_wait_registered "$INVENTORY_MODULE"

echo "⏳ Ждём ${RECOVERY_WAIT}s: обновление реестра у клиентов и закрытие circuit breaker..."
sleep "$RECOVERY_WAIT"

print_eureka_apps
run_collection "recovery.json" "Circuit Breaker: восстановление склада"

# --------------------------------------------------------------------------------------
# Фаза 4. Недоступен product-service
# --------------------------------------------------------------------------------------

echo ""
echo "=============================================================="
echo " Гасим $PRODUCT_MODULE — проверяем деградацию каталога"
echo "=============================================================="

svc_stop "$PRODUCT_MODULE"
sleep 10

run_collection "degraded-product.json" "Circuit Breaker: каталог недоступен"

echo ""
echo "✅ Проверка Circuit Breaker завершена"
