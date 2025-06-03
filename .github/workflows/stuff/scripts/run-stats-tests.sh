#!/bin/bash

# Проверка переменных окружения и установка значений по умолчанию
if [ -z "$BRANCH_NAME" ]; then
  BRANCH_NAME=${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}
fi

if [ -z "$BRANCH_NAME" ]; then
  echo "❌ Ошибка: Не удалось определить ветку."
  exit 1
fi

echo "Текущая ветка: $BRANCH_NAME"

ROOT_DIR="${ROOT_DIR:-./}"
# Создаем директорию логов, если ее нет
LOG_DIR="${LOG_DIR:-${ROOT_DIR}logs}"
mkdir -p "$LOG_DIR"

REPORTS_DIR="${REPORTS_DIR:-${ROOT_DIR}reports}"
mkdir -p "$REPORTS_DIR"

EUREKA_PORT=${EUREKA_PORT:-8761}
EUREKA_URL="http://localhost:${EUREKA_PORT}/eureka"

PRINT_LOGS="${PRINT_LOGS:-false}"
VERBOSE_MODE="${VERBOSE_MODE:-false}"
TESTER_VERSION=${TESTER_VERSION:-0.0.1}
STATS_TEST_MODE="${STATS_TEST_MODE:-ANALYZE}"

REQUIRED_SERVICES=()

case "$STATS_TEST_MODE" in
  "COLLECTION")
    REQUIRED_SERVICES=("collector")
    ;;
  "AGGREGATION")
    REQUIRED_SERVICES=("collector" "aggregator")
    ;;
  "ANALYZE")
    REQUIRED_SERVICES=("collector" "aggregator" "analyzer")
    ;;
  *)
    echo "⚠️ Неизвестный режим STATS_TEST_MODE: $STATS_TEST_MODE"
    ;;
esac

for service in "${REQUIRED_SERVICES[@]}"; do
  echo "⏳ Проверка регистрации сервиса $service в Eureka..."
  ATTEMPTS=0
  MAX_ATTEMPTS=10
  until curl -s -H "Accept: application/json" "${EUREKA_URL}/apps/${service^^}" | jq -e '.application.instance | length > 0' > /dev/null; do
    ((ATTEMPTS++))
    echo "⏳ $service не найден в Eureka... попытка $ATTEMPTS/$MAX_ATTEMPTS"
    if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
      echo "❌ Сервис $service не зарегистрирован в Eureka"
      exit 1
    fi
    sleep 5
  done
  echo "✅ Сервис $service зарегистрирован в Eureka"
done
sleep 20

echo "📋 Запуск сервиса Tester"

TESTER_JAR="${STUFF_PATH:-.github/workflows/stuff}/tester-${TESTER_VERSION}.jar"

CONFIG_ARGS="--tester.execution.mode=${STATS_TEST_MODE} \
--tester.execution.immediate-logging.enabled=${PRINT_LOGS} \
--tester.execution.output.trace-enabled=${VERBOSE_MODE} \
--tester.execution.output.print=true \
--tester.execution.output.file=true \
--tester.execution.output.file-path=${REPORTS_DIR}/execution-report.txt \
--eureka.client.serviceUrl.defaultZone=${EUREKA_URL}/"

if [ "${VERBOSE_MODE}" == "true" ]; then
    CONFIG_ARGS="$CONFIG_ARGS \
    --logging.level.ru.practicum=TRACE \
    --logging.level.['Лог выполнения']=TRACE"
fi

echo "🚀 Running: java -jar $TESTER_JAR $CONFIG_ARGS"
java -jar "$TESTER_JAR" $CONFIG_ARGS | tee "${LOG_DIR}/tester.log"

EXIT_CODE=${PIPESTATUS[0]}  # Берем код завершения первой команды (java)

if [[ $EXIT_CODE -ne 0 ]]; then
    echo "❌ Ошибка: во время выполнения tester'а было обнаружено $EXIT_CODE ошибок"
else
  echo "📋 tester завершился с кодом $EXIT_CODE"
fi

exit $EXIT_CODE