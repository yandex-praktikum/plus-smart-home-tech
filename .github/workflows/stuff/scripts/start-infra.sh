#!/bin/bash

set -e  # Останавливаем выполнение при ошибке

# Проверка переменных окружения и установка значений по умолчанию
if [ -z "$BRANCH_NAME" ]; then
  BRANCH_NAME=${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}
fi

if [ -z "$BRANCH_NAME" ]; then
  echo "❌ Ошибка: Не удалось определить ветку."
  exit 1
fi

echo "Текущая ветка: $BRANCH_NAME"

COMPOSE_PATH="${STUFF_PATH:-.github/workflows/stuff}/compose"

LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-password}
POSTGRES_HOST=${POSTGRES_HOST:-postgres}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_DB=${POSTGRES_DB:-telemetry_analyzer}

# Определяем, какие docker-compose файлы использовать
COMPOSE_FILES="$COMPOSE_PATH/docker-compose.yml" # в docker-compose.yml можно поместить настройки актуальные для всех веток

if [[ "$BRANCH_NAME" =~ ^(1-collector-json|2-collector-grpc|3-aggregator|4-analyzer|develop)$ ]]; then
  echo "Добавляем к запуску Kafka"
  COMPOSE_FILES="$COMPOSE_FILES -f $COMPOSE_PATH/kafka.yml"
fi

if [[ "$BRANCH_NAME" =~ ^(4-analyzer|5-config-server|6-discovery-server|7-microservices|7-spring-cloud-microservices|8-gateway|9-gateway-microservices|develop)$ ]]; then
  echo "Добавляем к запуску Postgres"
  COMPOSE_FILES="$COMPOSE_FILES -f $COMPOSE_PATH/postgres.yml"
fi

echo "🔧 Используемые файлы Docker Compose: $COMPOSE_FILES"

read -r -a compose_args <<< "-f $COMPOSE_FILES"

echo "🚀 Запуск инфраструктуры..."
docker compose "${compose_args[@]}" up --detach --wait --quiet-pull


echo "🩺 Проверка статуса контейнеров после запуска..."

FAILED=$(docker ps --filter health=unhealthy --format '{{.Names}}')
if [ -n "$FAILED" ]; then
  echo "❌ Обнаружены контейнеры со статусом unhealthy:"
  echo "$FAILED"
  exit 1
fi

# для отладки
echo "Сохраняю логи docker compose"

docker compose "${compose_args[@]}" logs > "$LOG_DIR/docker-compose.log" 2>&1
echo "Состояние запущенных контейнеров:"
docker compose "${compose_args[@]}" ps

echo "⏳ Ожидание запуска сервисов..."
if [[ "$COMPOSE_FILES" == *"kafka.yml"* ]]; then
    echo "📡 Ожидание Kafka..."
    MAX_RETRIES=10
    RETRY_DELAY=5
    attempt=0
    while ! docker exec kafka kafka-cluster cluster-id --bootstrap-server kafka:29092 &>/dev/null; do
        ((attempt++))
        echo "❌ Kafka ещё не готова, попытка $attempt/$MAX_RETRIES..."
        if [[ $attempt -ge $MAX_RETRIES ]]; then
            echo "⛔ Ошибка: Kafka не запустилась!"
            exit 1
        fi
        sleep $RETRY_DELAY
    done
    echo "✅ Kafka готова!"
fi

if [[ "$COMPOSE_FILES" == *"postgres.yml"* ]]; then
    echo "🛢️ Ожидание PostgreSQL..."
    MAX_RETRIES=10
    RETRY_DELAY=5
    attempt=0
    until docker exec postgres pg_isready -U postgres &>/dev/null; do
        ((attempt++))
        echo "❌ PostgreSQL ещё не готов, попытка $attempt/$MAX_RETRIES..."
        if [[ $attempt -ge $MAX_RETRIES ]]; then
            echo "⛔ Ошибка: PostgreSQL не запустился!"
            exit 1
        fi
        sleep $RETRY_DELAY
    done
    echo "✅ PostgreSQL готов!"
fi

echo "📋 Статус запущенных сервисов:"
docker compose "${compose_args[@]}" ps

echo "📂 Сохранение логов в $LOG_DIR..."
docker compose "${compose_args[@]}" logs > "$LOG_DIR/docker-compose.log" 2>&1

echo "✅ Инфраструктура успешно запущена!"