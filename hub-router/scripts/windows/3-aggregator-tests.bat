@echo off
setlocal

REM Локальный запуск тестов Hub Router для проверки связки Collector (grpc) + Aggregator

set "JAR_PATH=%~dp0..\hub-router.jar"

if "%1"=="info" (
  echo.
  java -jar "%JAR_PATH%" info
  echo.
  pause
  exit /b
)

echo "Запуск Hub Router (режим: AGGREGATION)"
echo.

java -jar "%JAR_PATH%" ^
  --hub-router.execution.mode=AGGREGATION ^
  --hub-router.execution.immediate-logging.enabled=false ^
  --hub-router.execution.output.info-enabled=true ^
  --hub-router.execution.output.trace-enabled=true ^
  --hub-router.execution.output.console=true ^
  --hub-router.skip-summary-on-startup=false


echo.
echo  Тест завершён. Проверьте результаты в консоли выше.
pause