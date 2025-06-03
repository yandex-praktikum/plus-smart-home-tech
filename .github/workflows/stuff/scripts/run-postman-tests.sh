#!/bin/bash

set -e

# Проверка переменных окружения и установка значений по умолчанию
if [ -z "$BRANCH_NAME" ]; then
  BRANCH_NAME=${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}
fi

if [ -z "$BRANCH_NAME" ]; then
  echo "❌ Ошибка: Не удалось определить ветку."
  exit 1
fi

EUREKA_PORT=${EUREKA_PORT:-8761}
EUREKA_URL="http://localhost:${EUREKA_PORT}/eureka"

echo "Текущая ветка: $BRANCH_NAME"

echo "🚀 Запуск Postman тестов для ветки: $BRANCH_NAME"

echo "📋 Список сервисов, зарегистрированных в Eureka:"
curl -s -H "Accept: application/json" "${EUREKA_URL}/apps" | jq .

COLLECTIONS_DIR="${STUFF_PATH}/postman/${BRANCH_NAME}"
REPORTS_DIR="${REPORTS_DIR:-./reports}"
TEMPLATE_PATH="${STUFF_PATH}/postman/dashboard-template.hbs"

mkdir -p "$REPORTS_DIR"

print_gateway_routes() {
  local service_name="gateway-server"

  echo "📡 Пробуем получить маршруты из $service_name через /actuator/gateway/routes..."

  local metadata=$(curl -s -H "Accept: application/json" "${EUREKA_URL}/apps/$service_name")
  local SERVICE_URL=$(echo "$metadata" | jq -r '.application.instance | if type=="array" then .[0] else . end | .homePageUrl // empty')

  if [[ -z "$SERVICE_URL" ]]; then
    echo "⚠️ Не удалось получить URL сервиса gateway-server из Eureka. Пробуем использовать http://localhost:8080"
    SERVICE_URL="http://localhost:8080"
  fi

  local routes_response=$(curl -s --connect-timeout 5 "${SERVICE_URL%/}/actuator/gateway/routes")
  if [[ -n "$routes_response" ]]; then
    echo "✅ Получены маршруты gateway:"
    echo "$routes_response" | jq .
  else
    echo "⚠️ Не удалось получить маршруты gateway. Возможно, actuator отключен."
  fi
}

print_gateway_routes

if [[ -f "${COLLECTIONS_DIR}/postman.json" ]]; then
 echo "▶️ Запуск 7-spring-cloud-microservices коллекции..."
 newman run "${COLLECTIONS_DIR}/postman.json" \
   --delay-request 50 -r cli,htmlextra \
   --verbose --color on --reporter-htmlextra-darkTheme \
   --reporter-htmlextra-export "${REPORTS_DIR}/7-spring-cloud-microservices.html" \
   --reporter-htmlextra-title "Отчет по тестам основного сервиса" \
   --reporter-htmlextra-logs true \
   --reporter-htmlextra-template "$TEMPLATE_PATH"
else
 echo "ℹ️ Коллекция 7-spring-cloud-microservices не найдена для ветки $BRANCH_NAME — пропуск."
fi
