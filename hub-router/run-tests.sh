#!/bin/bash

# Определяем текущую ветку
BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo "Текущая ветка: $BRANCH"
echo "--------------------------"

# Базовый путь к скриптам
SCRIPTS_PATH="scripts/macos_linux"

# Определяем, какой тестовый скрипт запустить
case "$BRANCH" in
  1-collector-json)
    TEST_SCRIPT="$SCRIPTS_PATH/1-collector-json-tests.sh"
    ;;
  2-collector-grpc)
    TEST_SCRIPT="$SCRIPTS_PATH/2-collector-grpc-tests.sh"
    ;;
  3-aggregator)
    TEST_SCRIPT="$SCRIPTS_PATH/3-aggregatorr-tests.sh"
    ;;
  4-analyzer)
    TEST_SCRIPT="$SCRIPTS_PATH/4-analyzer-tests.sh"
    ;;
  *)
    echo "❌ Неизвестная ветка: '$BRANCH'"
    echo "Этот скрипт поддерживает только ветки:"
    echo "  - 1-collector-json"
    echo "  - 2-collector-grpc"
    echo "  - 3-aggregator"
    echo "  - 4-analyzer"
    exit 1
    ;;
esac

# Проверяем, что нужный скрипт существует
if [ ! -f "$TEST_SCRIPT" ]; then
  echo "❌ Не найден скрипт: $TEST_SCRIPT"
  exit 1
fi

echo "✅ Запускаем тесты для ветки: $BRANCH"
echo "Используется скрипт: $TEST_SCRIPT"
echo "--------------------------"

# Запускаем соответствующий тестовый скрипт
bash "$TEST_SCRIPT"