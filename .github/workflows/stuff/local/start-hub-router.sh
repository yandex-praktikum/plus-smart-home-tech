#!/bin/bash

set -e  # Останавливаем выполнение при ошибке

if [ -z "$1" ]; then
  echo "❌ Ошибка: Не передан аргумент! Укажите один из: 1-collector-json, 2-collector-grpc, 3-aggregator, 4-analyzer"
  exit 1
fi

case "$1" in
  "1-collector-json")
    echo "🚀 Запуск hub-router в режиме HTTP Collector..."
    java -jar hub-router.jar --hub-router.execution.collector.mode=http --hub-router.execution.collector.port=8080
    ;;
  "2-collector-grpc")
    echo "🚀 Запуск hub-router в режиме gRPC Collector..."
    java -jar hub-router.jar
    ;;
  "3-aggregator")
    echo "🚀 Запуск hub-router в режиме Aggregator..."
    java -jar hub-router.jar --hub-router.execution.mode=AGGREGATION
    ;;
  "4-analyzer")
    echo "🚀 Запуск hub-router в режиме Analyzer..."
    java -jar hub-router.jar --hub-router.execution.mode=ANALYZE
    ;;
  *)
    echo "❌ Ошибка: Неверный аргумент '$1'. Доступные варианты: 1-collector-json, 2-collector-grpc, 3-aggregator, 4-analyzer"
    exit 1
    ;;
esac