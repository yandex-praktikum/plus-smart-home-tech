#!/bin/bash
set -e

COMPOSE_PATH="${STUFF_PATH:-.github/workflows/stuff}/compose"
LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

# Собираем все .yml файлы из папки $STUFF_PATH/compose
COMPOSE_FILES=$(ls $COMPOSE_PATH/*.yml | awk '{print "-f "$0}' | tr '\n' ' ')

if [[ -z "$COMPOSE_FILES" ]]; then
    echo "⚠️ В папке $COMPOSE_PATH нет файлов Compose. Завершаем работу."
    echo "📂 Сохраняем логи docker compose..."
    docker compose logs > "$LOG_DIR/docker-compose.log" 2>&1
    echo "🛑 Остановка всех сервисов..."
    docker compose down
else
    echo "📂 Сохраняем логи docker compose..."
    docker compose $COMPOSE_FILES logs > "$LOG_DIR/docker-compose.log" 2>&1
    echo "🛑 Остановка всех сервисов..."
    docker compose $COMPOSE_FILES down --volumes
fi

echo "✅ Инфраструктура остановлена."