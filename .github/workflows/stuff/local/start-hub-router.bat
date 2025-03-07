@echo off
setlocal

if "%~1"=="" (
    echo ❌ Ошибка: Не передан аргумент! Укажите один из: 1-collector-json, 2-collector-grpc, 3-aggregator, 4-analyzer
    exit /b 1
)

set MODE=%~1

if "%MODE%"=="1-collector-json" (
    echo 🚀 Запуск hub-router в режиме HTTP Collector...
    java -jar hub-router.jar --hub-router.execution.collector.mode=http --hub-router.execution.collector.port=8080
    exit /b
)

if "%MODE%"=="2-collector-grpc" (
    echo 🚀 Запуск hub-router в режиме gRPC Collector...
    java -jar hub-router.jar
    exit /b
)

if "%MODE%"=="3-aggregator" (
    echo 🚀 Запуск hub-router в режиме Aggregator...
    java -jar hub-router.jar --hub-router.execution.mode=AGGREGATION
    exit /b
)

if "%MODE%"=="4-analyzer" (
    echo 🚀 Запуск hub-router в режиме Analyzer...
    java -jar hub-router.jar --hub-router.execution.mode=ANALYZE
    exit /b
)

echo ❌ Ошибка: Неверный аргумент '%MODE%'. Доступные варианты: 1-collector-json, 2-collector-grpc, 3-aggregator, 4-analyzer
exit /b 1