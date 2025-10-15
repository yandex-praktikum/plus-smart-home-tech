@echo off
setlocal enabledelayedexpansion

for /f "tokens=*" %%b in ('git rev-parse --abbrev-ref HEAD') do set BRANCH=%%b

echo Текущая ветка: %BRANCH%
echo --------------------------

set SCRIPTS_PATH=scripts\windows

if "%BRANCH%"=="1-collector-json" (
    set TEST_SCRIPT=%SCRIPTS_PATH%\1-collector-json-tests.bat
) else if "%BRANCH%"=="2-collector-grpc" (
    set TEST_SCRIPT=%SCRIPTS_PATH%\2-collector-grpc-tests.bat
) else if "%BRANCH%"=="3-aggregator" (
    set TEST_SCRIPT=%SCRIPTS_PATH%\3-aggregatorr-tests.bat
) else if "%BRANCH%"=="4-analyzer" (
    set TEST_SCRIPT=%SCRIPTS_PATH%\4-analyzer-tests.bat
) else (
    echo ❌ Неизвестная ветка: "%BRANCH%"
    echo Этот скрипт поддерживает только ветки:
    echo   - 1-collector-json
    echo   - 2-collector-grpc
    echo   - 3-aggregator
    echo   - 4-analyzer
    exit /b 1
)

if not exist "%TEST_SCRIPT%" (
    echo ❌ Не найден скрипт: %TEST_SCRIPT%
    exit /b 1
)

echo ✅ Запускаем тесты для ветки: %BRANCH%
echo Используется скрипт: %TEST_SCRIPT%
echo --------------------------

call "%TEST_SCRIPT%"