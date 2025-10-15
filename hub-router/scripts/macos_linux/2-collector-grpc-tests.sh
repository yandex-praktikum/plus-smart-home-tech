#!/bin/bash
# Локальный запуск тестов Hub Router для проверки сервиса Collector

set -e

JAR_PATH="$(dirname "$0")/../hub-router.jar"

if [[ "$1" == "info" ]]; then
  java -jar "$JAR_PATH" info
else
  echo "Запуск Hub Router (режим: COLLECTION, GRPC)"
  java -jar "$JAR_PATH" \
    --hub-router.execution.mode=COLLECTION \
    --hub-router.execution.collector.mode=grpc \
    --hub-router.execution.immediate-logging.enabled=false \
    --hub-router.execution.output.info-enabled=true \
    --hub-router.execution.output.trace-enabled=true \
    --hub-router.execution.output.console=true \
    --hub-router.execution.output.file=false \
    --hub-router.skip-summary-on-startup=false
fi