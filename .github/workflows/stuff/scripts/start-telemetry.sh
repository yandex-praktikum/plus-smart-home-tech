#!/bin/bash

BRANCH_NAME=${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}

echo "Проверка наличия JAR-файлов и запуск нужных сервисов..."

WAIT_FOR_IT="$(dirname "$0")/wait-for-it.sh"

# Создаем директорию логов, если ее нет
LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

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

# Для сервисов работающих с бд
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-password}
POSTGRES_PORT=${POSTGRES_PORT:-5432}

# Определяем JAR-файлы
COLLECTOR_JAR=$(find_jar "collector")
AGGREGATOR_JAR=$(find_jar "aggregator")
ANALYZER_JAR=$(find_jar "analyzer")

# Выводим найденные файлы
echo "Найденные JAR-файлы:"
echo "Collector: $COLLECTOR_JAR"
echo "Aggregator: $AGGREGATOR_JAR"
echo "Analyzer: $ANALYZER_JAR"

echo "Текущая ветка: $BRANCH_NAME"

start_service() {
  local service_name=$1
  local jar_path=$2
  local extra_args=$3
  local log_file="${LOG_DIR}/${service_name}.log"

  if [ -z "$jar_path" ]; then
    echo "❌ Ошибка: JAR-файл для сервиса $service_name не найден."
    exit 1
  fi

  echo "⏳ Запуск сервиса $service_name..."
  nohup java -jar "$jar_path" $extra_args --logging.file.name="$log_file" > "$log_file" 2>&1 &

  # Ждем несколько секунд и проверяем, запустился ли процесс
  sleep 5
  if ! pgrep -f "$jar_path" > /dev/null; then
    echo "❌ Ошибка: Сервис $service_name не запустился. Проверьте логи: $log_file"
    cat "$log_file"
    exit 1
  fi
  echo "✅ Сервис $service_name успешно запущен."
}

check_collector() {
  local collector_port=$1

  # Проверка, существует ли wait-for-it.sh
  if [ -f "$WAIT_FOR_IT" ]; then
    $WAIT_FOR_IT localhost:${collector_port} --timeout=10 --strict -- echo "✅ Collector is up and ready"
  fi
}

# Логика запуска в зависимости от ветки
case "$BRANCH_NAME" in
  "1-collector-json")
    start_service "collector" "$COLLECTOR_JAR" "--server.port=8080"
    check_collector "8080"
    ;;
  "2-collector-grpc")
    start_service "collector" "$COLLECTOR_JAR" "--grpc.server.port=59091"
    check_collector "59091"
    ;;
  "3-aggregator")
    start_service "collector" "$COLLECTOR_JAR" "--grpc.server.port=59091"
    start_service "aggregator" "$AGGREGATOR_JAR" ""
    check_collector "59091"
    ;;
  "4-analyzer")
    start_service "collector" "$COLLECTOR_JAR" "--grpc.server.port=59091"
    start_service "aggregator" "$AGGREGATOR_JAR" ""
    start_service "analyzer" "$ANALYZER_JAR" \
      "--spring.datasource.url=jdbc:postgresql://localhost:${POSTGRES_PORT}/telemetry_analyzer \
       --spring.datasource.username=${POSTGRES_USER} \
       --spring.datasource.password=${POSTGRES_PASSWORD}"
    check_collector "59091"
    ;;
  "develop")
    start_service "collector" "$COLLECTOR_JAR" "--grpc.server.port=59091"
    start_service "aggregator" "$AGGREGATOR_JAR" ""
    start_service "analyzer" "$ANALYZER_JAR" \
      "--spring.datasource.url=jdbc:postgresql://localhost:${POSTGRES_PORT}/telemetry_analyzer \
       --spring.datasource.username=${POSTGRES_USER} \
       --spring.datasource.password=${POSTGRES_PASSWORD}"
    check_collector "59091"
    ;;
  *)
    echo "❌ Ошибка: Ветка $BRANCH_NAME не поддерживается этим workflow."
    exit 1
    ;;
esac