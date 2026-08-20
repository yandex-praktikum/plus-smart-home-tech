#!/bin/bash

# Определяет "этап" решения — набор сервисов, которые нужно запустить и протестировать.
#
# Для веток заданий этап однозначно определяется именем ветки.
# Для интеграционных веток develop и development имя ветки ничего не говорит об их содержимом,
# поэтому этап определяется по коду решения:
#   * реализованы микросервисы витрины (shopping-store, shopping-cart, warehouse)
#     -> "7-spring-cloud-microservices" (запускаем postman-тесты);
#   * реализованы микросервисы магазина (product-service, order-service, inventory-service)
#     -> "7-microservices" (запускаем postman-тесты);
#   * иначе в ветке только телеметрия (этап 4-analyzer)
#     -> "develop" (запускаем текущие тесты hub-router).
#
# Результат печатается в stdout, диагностика — в stderr.

set -e

if [ -z "$BRANCH_NAME" ]; then
  BRANCH_NAME=${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}
fi

if [ -z "$BRANCH_NAME" ]; then
  echo "❌ Ошибка: Не удалось определить ветку." >&2
  exit 1
fi

ROOT_DIR="${ROOT_DIR:-.}"

log() {
  echo "$@" >&2
}

# Каталоги модуля: ищем и по имени каталога, и по artifactId в pom.xml,
# чтобы не зависеть от того, как студент разложил модули по проекту.
service_dirs() {
  local name=$1

  {
    find "$ROOT_DIR" -type d -name "$name" \
      -not -path "*/target/*" -not -path "*/.git/*" 2>/dev/null || true

    find "$ROOT_DIR" -name pom.xml \
      -not -path "*/target/*" -not -path "*/.git/*" \
      -exec grep -l "<artifactId>${name}</artifactId>" {} + 2>/dev/null \
      | while IFS= read -r pom; do dirname "$pom"; done || true
  } | sort -u
}

# Сервис считается реализованным, если в его каталоге есть Spring Boot приложение.
# Пустой модуль-заготовка (только pom.xml) под это условие не подходит.
has_service() {
  local name=$1
  local dir

  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    if grep -rlq --include="*.java" "@SpringBootApplication" "$dir" 2>/dev/null; then
      log "   ✔ $name: $dir"
      return 0
    fi
  done <<< "$(service_dirs "$name")"

  return 1
}

# Возвращает 0, только если реализованы все перечисленные сервисы.
has_all_services() {
  local missing=()
  local service

  for service in "$@"; do
    if ! has_service "$service"; then
      missing+=("$service")
    fi
  done

  if [ ${#missing[@]} -ne 0 ]; then
    log "   ✖ не найдены сервисы: ${missing[*]}"
    return 1
  fi

  return 0
}

detect_stage_by_code() {
  if has_all_services "shopping-store" "shopping-cart" "warehouse"; then
    log "🔎 В решении реализованы микросервисы витрины — этап 7-spring-cloud-microservices"
    echo "7-spring-cloud-microservices"
    return 0
  fi

  if has_all_services "product-service" "order-service" "inventory-service"; then
    log "🔎 В решении реализованы микросервисы магазина — этап 7-microservices"
    echo "7-microservices"
    return 0
  fi

  log "🔎 Микросервисов не найдено — в решении только телеметрия (этап 4-analyzer)"
  echo "develop"
}

case "$BRANCH_NAME" in
  "develop" | "development")
    log "🔎 Ветка $BRANCH_NAME: определяем этап по коду решения..."
    detect_stage_by_code
    ;;
  *)
    log "🔎 Ветка $BRANCH_NAME: этап определяется именем ветки"
    echo "$BRANCH_NAME"
    ;;
esac
