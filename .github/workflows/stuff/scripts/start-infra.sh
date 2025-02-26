#!/bin/bash

set -e  # Останавливаем выполнение при ошибке

LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

echo "🔧 Поиск файла Docker Compose..."
if [ -f "docker-compose.yaml" ]; then
    COMPOSE_FILE="docker-compose.yaml"
elif [ -f "compose.yaml" ]; then
    COMPOSE_FILE="compose.yaml"
elif [ -f "docker-compose.yml" ]; then
    COMPOSE_FILE="docker-compose.yml"
else
    echo "❌ Ошибка: Не найден файл Docker Compose!"
    exit 1
fi

echo "🚀 Запуск инфраструктуры из $COMPOSE_FILE..."
docker compose -f "$COMPOSE_FILE" up --detach

echo "🔍 Проверяем, есть ли Kafka в docker-compose..."
if docker compose config | grep -q 'kafka:'; then

  echo "⏳ Ожидание полной готовности Kafka..."
  MAX_RETRIES=10  # Максимальное число попыток
  RETRY_DELAY=5   # Задержка между попытками (в секундах)
  attempt=0

  while ! docker exec kafka kafka-cluster cluster-id --bootstrap-server kafka:29092 &>/dev/null; do
    ((attempt++))
    echo "❌ Kafka ещё не готова, попытка $attempt/$MAX_RETRIES..."
    if [[ $attempt -ge $MAX_RETRIES ]]; then
      echo "⛔ Ошибка: Kafka не запустилась после $((MAX_RETRIES * RETRY_DELAY)) секунд!"
      exit 1
    fi
    sleep $RETRY_DELAY
  done

  echo "✅ Kafka готова!"
fi

echo "📋 Статус запущенных сервисов:"
docker compose ps

echo "✅ Инфраструктура успешно запущена!"