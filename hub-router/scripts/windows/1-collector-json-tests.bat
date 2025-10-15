@echo off
setlocal

REM Локальный запуск тестов Hub Router для проверки сервиса Collector

set "JAR_PATH=%~dp0..\hub-router.jar"

if "%1"=="info" (
  echo.
  java -jar "%JAR_PATH%" info
  echo.
  pause
  exit /b
)

echo "Запуск Hub Router (режим: COLLECTION, HTTP)"
echo.

java -jar "%JAR_PATH%" ^
  --hub-router.execution.mode=COLLECTION ^
  --hub-router.execution.collector.mode=http ^
  --hub-router.execution.immediate-logging.enabled=false ^
  --hub-router.execution.output.info-enabled=true ^
  --hub-router.execution.output.trace-enabled=true ^
  --hub-router.execution.output.console=true ^
  --hub-router.skip-summary-on-startup=false

echo.
echo  Тест завершён. Проверьте результаты в консоли выше.
pause