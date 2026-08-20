#!/bin/bash

# Запуск сервисов для веток, где уже есть платформенная инфраструктура
# (config-server, discovery-server, gateway) и микросервисы.
#
# Скрипт дополнительно фиксирует список запущенных сервисов в $STARTED_SERVICES_FILE,
# чтобы check-config-clients.sh мог проверить, что каждый сервис получил
# конфигурацию из config-server.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./service-control.sh
source "${SCRIPT_DIR}/service-control.sh"

# Проверка переменных окружения и установка значений по умолчанию
if [ -z "$BRANCH_NAME" ]; then
  BRANCH_NAME=${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}
fi

if [ -z "$BRANCH_NAME" ]; then
  echo "❌ Ошибка: Не удалось определить ветку."
  exit 1
fi

echo "Текущая ветка: $BRANCH_NAME"

if ! command -v jq &> /dev/null; then
  echo "❌ Ошибка: Утилита jq не установлена."
  exit 1
fi

WAIT_FOR_IT="${SCRIPT_DIR}/wait-for-it.sh"

# Создаем директорию логов, если ее нет
LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"
ROOT_DIR="${ROOT_DIR:-./}"

# Для сервисов работающих с бд
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-password}
POSTGRES_PORT=${POSTGRES_PORT:-5432}

EUREKA_PORT=${EUREKA_PORT:-8761}
EUREKA_URL="http://localhost:${EUREKA_PORT}/eureka"

# Включается, когда в ветке запускается discovery-server
EUREKA_ENABLED=false

# Аргументы, которые добавляются каждому клиенту config-server.
# Аргументы командной строки имеют наивысший приоритет и не могут быть переопределены
# конфигурацией, полученной с config-server, — это гарантирует, что в логе сервиса
# останутся сообщения Spring Cloud Config Client о загрузке конфигурации.
CONFIG_CLIENT_ARGS="--logging.level.org.springframework.cloud.config=DEBUG"

# Ускоряем обновление реестра Eureka у клиентов: тесты отказоустойчивости гасят и
# поднимают сервисы, и соседи должны узнавать об этом быстро, а не через 30 секунд.
DISCOVERY_CLIENT_ARGS="--eureka.client.registry-fetch-interval-seconds=5 --eureka.instance.lease-renewal-interval-in-seconds=5"

# Списки запущенных сервисов создаём заново при каждом запуске
: > "$STARTED_SERVICES_FILE"
: > "$SERVICE_COMMANDS_FILE"

# Функция поиска правильного JAR'ника
find_jar() {
  local service=$1
  local jar_path

  # Ищем *-boot.jar сначала
  jar_path=$(find ./ -name "${service}-*-boot.jar" | head -n 1)
  if [ -z "$jar_path" ]; then
    # Если нет boot-версии, ищем обычный JAR
    jar_path=$(find ./ -name "${service}-*.jar" | head -n 1)
  fi

  echo "$jar_path"
}

# Имя приложения (spring.application.name) может не совпадать с именем модуля:
# например, модуль gateway-server регистрируется в Eureka как gateway.
resolve_app_name() {
  local module=$1
  local extra_args=$2
  local name dir

  name=$(echo "$extra_args" | grep -oE -- '--spring\.application\.name=[^ ]+' | head -n 1 | cut -d= -f2-)

  if [ -z "$name" ]; then
    dir=$(cfg_module_dir_by_name "$module" 2>/dev/null)
    [ -n "$dir" ] && name=$(cfg_module_app_name "$dir")
  fi

  [ -z "$name" ] && name="$module"
  echo "$name"
}

check_eureka_registration() {
  local service_name=$1
  local attempts=${2:-12}
  local i

  echo "⏳ Проверка регистрации $service_name в Eureka..."

  for ((i = 1; i <= attempts; i++)); do
    if curl -s -H "Accept: application/json" "${EUREKA_URL}/apps/$service_name" \
         | jq -e '.application.instance | if type=="array" then length > 0 else . != null end' > /dev/null 2>&1; then
      echo "✅ Сервис $service_name зарегистрирован в Eureka."
      return 0
    fi
    echo "⏳ Ждём регистрации $service_name в Eureka... ($i/$attempts)"
    sleep 5
  done

  echo "❌ Сервис $service_name не зарегистрировался в Eureka."
  echo "📋 Список приложений, зарегистрированных в Eureka:"
  curl -s -H "Accept: application/json" "${EUREKA_URL}/apps" | jq .
  return 1
}

check_http_service() {
  local service_name=$1
  echo "⏳ Проверка доступности HTTP-сервиса $service_name в Eureka..."

  for i in {1..10}; do
    local metadata=$(curl -s -H "Accept: application/json" "${EUREKA_URL}/apps/$service_name")

    if [[ -z "$metadata" ]]; then
      echo "⏳ Ждём регистрации $service_name в Eureka... ($i/10)"
      sleep 5
      continue
    fi

    local SERVICE_URL=$(echo "$metadata" | jq -r '.application.instance | if type=="array" then .[0] else . end | .homePageUrl // empty')

    if [[ -n "$SERVICE_URL" ]]; then
      echo "✅ Найден адрес $service_name: $SERVICE_URL"

      # 1. Попробуем проверить /actuator/health
      if curl -s --connect-timeout 5 "${SERVICE_URL%/}/actuator/health" | jq -e '.status == "UP"' > /dev/null; then
        echo "✅ HTTP-сервис $service_name доступен и здоров (по actuator/health)."
        return
      fi

      # 2. Если не удалось — просто проверим, что сервис отвечает
      if curl -s --connect-timeout 5 "$SERVICE_URL" > /dev/null; then
        echo "⚠️  Сервис $service_name отвечает, но не отдает статус 'UP' (возможно, нет actuator/health)"
        return
      else
        echo "❌ Сервис $service_name пока не отвечает... ($i/10)"
      fi
    else
      echo "⏳ Ждём регистрации $service_name в Eureka... ($i/10)"
    fi

    sleep 3
  done

  echo "❌ Не удалось проверить доступность HTTP-сервиса $service_name."
  echo "📋 Список приложений, зарегистрированных в Eureka:"
  curl -s -H "Accept: application/json" "${EUREKA_URL}/apps" | jq .
  exit 1
}

# Отдельно ловим типовые ошибки старта Spring Boot, в том числе неудачную попытку
# получить конфигурацию с config-server.
check_startup_errors() {
  local service_name=$1
  local log_file=$2

  if grep -Eq "APPLICATION FAILED TO START|Application run failed|ConfigClientFailFastException" "$log_file" 2>/dev/null; then
    echo "❌ Ошибка: Сервис $service_name не смог стартовать. Фрагмент лога:"
    grep -E -A 10 "APPLICATION FAILED TO START|Application run failed|ConfigClientFailFastException" "$log_file" | head -n 40
    exit 1
  fi
}

start_service() {
  local service_name=$1
  local extra_args=$2
  local registration_check=${3:-http}

  local jar_path="$(find_jar $service_name)"
  local log_file="${LOG_DIR}/${service_name}.log"

  if [ -z "$jar_path" ]; then
    echo "❌ Ошибка: JAR-файл для сервиса $service_name не найден."
    exit 1
  fi

  local app_name
  app_name=$(resolve_app_name "$service_name" "$extra_args")

  local eureka_args=""
  if [ "$EUREKA_ENABLED" = "true" ]; then
    eureka_args="--eureka.client.serviceUrl.defaultZone=${EUREKA_URL}/ $DISCOVERY_CLIENT_ARGS"
  fi

  # Команду запоминаем целиком, чтобы тесты отказоустойчивости могли перезапустить сервис
  local command="java -jar \"$jar_path\" $extra_args $eureka_args --logging.file.name=\"$log_file\""

  echo "⏳ Запуск сервиса $service_name (имя приложения: $app_name)..."
  eval "nohup $command > \"$log_file\" 2>&1 &"
  local pid=$!

  svc_record "$service_name" "$app_name" "$pid" "$log_file" "$command"

  # В список для проверки клиентов config-server попадают только прикладные сервисы:
  # сам config-server и discovery-server клиентами быть не обязаны.
  case " $CONFIG_CLIENT_EXCLUDES " in
    *" $service_name "*) ;;
    *) printf '%s\t%s\t%s\n' "$app_name" "$log_file" "$service_name" >> "$STARTED_SERVICES_FILE" ;;
  esac

  sleep 15
  check_startup_errors "$service_name" "$log_file"

  if ! svc_is_running "$pid" && ! pgrep -f "$jar_path" > /dev/null; then
    echo "❌ Ошибка: Сервис $service_name не запустился. Проверьте логи: $log_file"
    cat "$log_file"
    exit 1
  fi

  case "$registration_check" in
    http)
      check_http_service "$app_name"
      ;;
    eureka)
      check_eureka_registration "$app_name" || exit 1
      ;;
    none)
      ;;
  esac

  echo "✅ Сервис $service_name успешно запущен и готов к работе."
}

start_stateful_service() {
  local service_name=$1
  local db_name=$2
  local extra_args=$3
  local registration_check=${4:-http}

  extra_args+=" --spring.datasource.url=jdbc:postgresql://localhost:${POSTGRES_PORT}/$db_name"
  extra_args+=" --spring.datasource.username=${POSTGRES_USER}"
  extra_args+=" --spring.datasource.password=${POSTGRES_PASSWORD}"

  start_service $service_name "$extra_args" "$registration_check"
}

# Запускает сервис, только если его модуль (и собранный JAR) присутствуют в ветке
start_optional_stateful_service() {
  local service_name=$1
  local db_name=$2
  local extra_args=$3
  local registration_check=${4:-http}

  if [ -z "$(find_jar "$service_name")" ]; then
    echo "ℹ️  Модуль $service_name в этой ветке отсутствует — пропускаем."
    return 0
  fi

  start_stateful_service "$service_name" "$db_name" "$extra_args" "$registration_check"
}

start_discovery_server() {
  EUREKA_ENABLED=true
  start_service "discovery-server" "--server.port=${EUREKA_PORT}" "none"
  $WAIT_FOR_IT localhost:${EUREKA_PORT} --timeout=60 --strict -- echo "✅ Eureka is up"
}

start_config_server() {
  start_service "config-server" "" "none"

  # config-server можно поднимать двумя способами: на фиксированном порту
  # или на случайном с регистрацией в Eureka. Ждать регистрации нужно только
  # во втором случае — иначе адрес сервера конфигурации неоткуда взять.
  local dir port
  dir=$(cfg_config_server_dir 2>/dev/null)
  [ -n "$dir" ] && port=$(cfg_module_server_port "$dir")

  if [ "$EUREKA_ENABLED" = "true" ] && { [ -z "$port" ] || [ "$port" = "0" ]; }; then
    check_eureka_registration "$(cfg_module_app_name "$dir")" || exit 1
  fi

  local base_url
  base_url=$(cfg_config_server_url)
  echo "⏳ Ожидание готовности config-server по адресу $base_url..."

  if ! cfg_wait_for_config_server "$base_url"; then
    echo "❌ Ошибка: config-server не отвечает по адресу $base_url. Лог сервиса:"
    tail -n 60 "${LOG_DIR}/config-server.log"
    exit 1
  fi

  echo "✅ config-server готов: $base_url"
}

start_platform_core() {
  start_discovery_server
  start_config_server
  sleep 5
}

# Телеметрия — сервисы, которые есть уже на ветках 5-config-server и 6-discovery-server
start_telemetry_services() {
  local registration_check=${1:-none}

  start_service "collector" "$CONFIG_CLIENT_ARGS" "$registration_check"
  start_service "aggregator" "$CONFIG_CLIENT_ARGS" "$registration_check"
  start_stateful_service "analyzer" "telemetry_analyzer" "$CONFIG_CLIENT_ARGS" "$registration_check"
}

# Микросервисы витрины (трек 7-spring-cloud-microservices / 8-gateway / 9-gateway-microservices)
start_commerce_showcase_services() {
  start_stateful_service "warehouse" "commerce_warehouse" "--spring.application.name=warehouse $CONFIG_CLIENT_ARGS"
  start_stateful_service "shopping-cart" "commerce_shopping_cart" "--spring.application.name=shopping-cart $CONFIG_CLIENT_ARGS"
  start_stateful_service "shopping-store" "commerce_shopping_store" "--spring.application.name=shopping-store $CONFIG_CLIENT_ARGS"

  start_optional_stateful_service "order" "commerce_order" "--spring.application.name=order $CONFIG_CLIENT_ARGS"
  start_optional_stateful_service "payment" "commerce_payment" "--spring.application.name=payment $CONFIG_CLIENT_ARGS"
  start_optional_stateful_service "delivery" "commerce_delivery" "--spring.application.name=delivery $CONFIG_CLIENT_ARGS"
}

# Микросервисы магазина (трек 7-microservices / 8-open-feign / 9-circuit-breaker / 10 / 11)
start_commerce_shop_services() {
  start_stateful_service "inventory-service" "inventory_db" "--spring.application.name=inventory-service $CONFIG_CLIENT_ARGS"
  start_stateful_service "order-service" "order_db" "--spring.application.name=order-service $CONFIG_CLIENT_ARGS"
  start_stateful_service "product-service" "product_db" "--spring.application.name=product-service $CONFIG_CLIENT_ARGS"
}

# Gateway в разных решениях называется по-разному
start_gateway() {
  local module

  for module in gateway-server api-gateway gateway; do
    if [ -n "$(find_jar "$module")" ]; then
      start_service "$module" "$CONFIG_CLIENT_ARGS" "http"
      return 0
    fi
  done

  echo "❌ Ошибка: не найден JAR gateway-сервиса (gateway-server / api-gateway / gateway)."
  exit 1
}

echo "Проверка наличия JAR-файлов и запуск нужных сервисов..."

# Логика запуска в зависимости от ветки
case "$BRANCH_NAME" in
  "5-config-server")
    start_config_server
    start_telemetry_services "none"

    sleep 10
    ;;
  "6-discovery-server")
    start_platform_core

    sleep 10

    start_telemetry_services "eureka"

    sleep 10
    ;;
  "7-spring-cloud-microservices")
    start_platform_core

    sleep 10

    start_stateful_service "warehouse" "commerce_warehouse" "--spring.application.name=warehouse $CONFIG_CLIENT_ARGS"
    start_stateful_service "shopping-cart" "commerce_shopping_cart" "--spring.application.name=shopping-cart $CONFIG_CLIENT_ARGS"
    start_stateful_service "shopping-store" "commerce_shopping_store" "--spring.application.name=shopping-store $CONFIG_CLIENT_ARGS"

    sleep 10
    ;;
  "7-microservices")
    start_platform_core

    sleep 10

    start_commerce_shop_services

    sleep 10
    ;;
  "8-gateway" | "9-gateway-microservices")
    start_platform_core

    sleep 10

    start_commerce_showcase_services
    start_gateway

    sleep 10
    ;;
  "8-open-feign" | "9-circuit-breaker")
    start_platform_core

    sleep 10

    start_commerce_shop_services

    sleep 10
    ;;
  "10-gateway-load-balancing" | "11-security")
    start_platform_core

    sleep 10

    start_commerce_shop_services
    start_gateway

    sleep 10
    ;;
  *)
    echo "❌ Ошибка: Ветка $BRANCH_NAME не поддерживается этим workflow."
    exit 1
    ;;
esac

echo "📋 Запущенные сервисы:"
cat "$STARTED_SERVICES_FILE"
