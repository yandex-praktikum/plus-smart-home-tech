#!/bin/bash

if [ -z "$BRANCH_NAME" ]; then
  BRANCH_NAME=${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}
fi

# Создаем директорию логов, если ее нет
LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

PRINT_LOGS="${PRINT_LOGS:-false}"
VERBOSE_MODE="${VERBOSE_MODE:-false}"


echo "📋 Запуск сервиса Hub Router с настройками для ветки $BRANCH_NAME"

HUB_ROUTER_JAR="${STUFF_PATH:-.github/workflows/stuff}/hub-router.jar"

CONFIG_ARGS="--hub-router.execution.immediate-logging.enabled=${PRINT_LOGS} \
--hub-router.execution.output.trace-enabled=${VERBOSE_MODE} \
--hub-router.execution.output.print=true \
--hub-router.execution.output.file=true"

if [ "${VERBOSE_MODE}" == "true" ]; then
    CONFIG_ARGS="$CONFIG_ARGS \
    --logging.level.ru.yandex.practicum=TRACE \
    --logging.level.['Лог выполнения']=TRACE"
fi

case "$BRANCH_NAME" in
  "1-collector-json")
    CONFIG_ARGS="$CONFIG_ARGS --hub-router.execution.collector.mode=http --hub-router.execution.collector.port=8080 --hub-router.execution.mode=COLLECTION"
    ;;
  "2-collector-grpc")
    CONFIG_ARGS="$CONFIG_ARGS --hub-router.execution.collector.port=59091 --hub-router.execution.mode=COLLECTION"
    ;;
  "3-aggregator")
    CONFIG_ARGS="$CONFIG_ARGS --hub-router.execution.collector.port=59091 --hub-router.execution.mode=AGGREGATION"
    ;;
  "4-analyzer" | "develop")
    CONFIG_ARGS="$CONFIG_ARGS --hub-router.execution.collector.port=59091 --hub-router.execution.mode=ANALYZE"
    ;;
  *)
    echo "❌ Ошибка: Ветка $BRANCH_NAME не поддерживается для тестов."
    exit 1
    ;;
esac

echo "🚀 Running: java -jar $HUB_ROUTER_JAR $CONFIG_ARGS"
java -jar "$HUB_ROUTER_JAR" $CONFIG_ARGS | tee "${LOG_DIR}/hub-router.log"

EXIT_CODE=${PIPESTATUS[0]}  # Берем код завершения первой команды (java)

if [[ $EXIT_CODE -ne 0 ]]; then
    echo "❌ Ошибка: во время выполнения hub-router было обнаружено $EXIT_CODE ошибок"
else
  echo "📋 hub-router завершился с кодом $EXIT_CODE"
fi

exit $EXIT_CODE