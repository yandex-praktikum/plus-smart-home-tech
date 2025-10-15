#!/bin/bash
# Локальный запуск тестов Hub Router для проверки полного комплекса Collector (grpc) + Aggregator + Analyzer

set -e

JAR_PATH="$(dirname "$0")/../hub-router.jar"

if [[ "$1" == "info" ]]; then
  java -jar "$JAR_PATH" info
else
  echo "Запуск Hub Router (режим: ANALYZE)"
  java -jar "$JAR_PATH" \
    --hub-router.execution.mode=ANALYZE \
    --hub-router.execution.immediate-logging.enabled=false \
    --hub-router.execution.output.info-enabled=true \
    --hub-router.execution.output.trace-enabled=true \
    --hub-router.execution.output.console=true \
    --hub-router.execution.output.file=false \
    --hub-router.skip-summary-on-startup=false
fi