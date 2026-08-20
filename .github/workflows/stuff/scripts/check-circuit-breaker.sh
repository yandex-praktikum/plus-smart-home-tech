#!/bin/bash

# Проверка того, что в решении действительно применён паттерн Circuit Breaker
# (этап 9-circuit-breaker и последующие).
#
# Проверяется по исходникам:
#   1. подключена реализация Spring Cloud Circuit Breaker (Resilience4j);
#   2. у Feign-клиентов задан fallback / fallbackFactory либо включена
#      интеграция OpenFeign с circuit breaker;
#   3. заданы настройки resilience4j (мягкая проверка).
#
# Поведение под нагрузкой (деградация и восстановление) проверяется
# postman-тестами через run-circuit-breaker-tests.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./config-lib.sh
source "${SCRIPT_DIR}/config-lib.sh"

ERRORS=0

fail() {
  cfg_err "$*"
  ERRORS=$((ERRORS + 1))
}

# Реализации Spring Cloud Circuit Breaker
CIRCUIT_BREAKER_ARTIFACTS="spring-cloud-starter-circuitbreaker-resilience4j spring-cloud-starter-circuitbreaker-reactor-resilience4j resilience4j-spring-boot3 resilience4j-spring-boot2"

echo "🔧 Проверка Circuit Breaker (ветка: ${BRANCH_NAME:-${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}})"

# --------------------------------------------------------------------------------------
# Feign-клиенты проекта
# --------------------------------------------------------------------------------------

feign_client_files() {
  grep -rl --include="*.java" --include="*.kt" "@FeignClient" "$ROOT_DIR" 2>/dev/null \
    | grep -v "/target/" | grep -v "/src/test/" | sort -u
}

echo ""
echo "=== 1. Проверка зависимости Circuit Breaker ==="

FOUND_DEPENDENCY=""
for artifact in $CIRCUIT_BREAKER_ARTIFACTS; do
  pom=$(grep -rl --include="pom.xml" "<artifactId>${artifact}</artifactId>" "$ROOT_DIR" 2>/dev/null \
        | grep -v "/target/" | head -n 1)
  if [ -n "$pom" ]; then
    FOUND_DEPENDENCY="$artifact"
    cfg_ok "Подключена реализация Circuit Breaker: $artifact ($pom)"
    break
  fi
done

if [ -z "$FOUND_DEPENDENCY" ]; then
  fail "Не найдена зависимость Circuit Breaker (ожидается spring-cloud-starter-circuitbreaker-resilience4j)"
fi

echo ""
echo "=== 2. Проверка защиты вызовов между сервисами ==="

CLIENT_FILES=$(feign_client_files)

if [ -z "$CLIENT_FILES" ]; then
  fail "В проекте не найдено ни одного @FeignClient — нечего защищать Circuit Breaker'ом"
else
  PROTECTED=0
  UNPROTECTED=""

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if grep -Eq "fallback[[:space:]]*=|fallbackFactory[[:space:]]*=" "$file" 2>/dev/null; then
      cfg_ok "$(basename "$file"): задан fallback/fallbackFactory"
      PROTECTED=$((PROTECTED + 1))
    else
      UNPROTECTED="${UNPROTECTED} $(basename "$file")"
    fi
  done <<< "$CLIENT_FILES"

  # Интеграция OpenFeign с circuit breaker может быть включена настройкой,
  # тогда вызовы оборачиваются даже без явного fallback.
  CB_ENABLED=$(grep -rl --include="*.yml" --include="*.yaml" --include="*.properties" \
                 -E "circuitbreaker" "$ROOT_DIR" 2>/dev/null | grep -v "/target/" | head -n 1)

  if [ "$PROTECTED" -eq 0 ] && [ -z "$CB_ENABLED" ]; then
    fail "Ни у одного Feign-клиента нет fallback/fallbackFactory и не включена интеграция OpenFeign с circuit breaker"
  fi

  if [ -n "$UNPROTECTED" ]; then
    cfg_warn "Без fallback/fallbackFactory:${UNPROTECTED}"
  fi

  if [ -n "$CB_ENABLED" ]; then
    cfg_ok "Найдена настройка circuit breaker: $CB_ENABLED"
  fi
fi

echo ""
echo "=== 3. Проверка настроек resilience4j ==="

R4J_CONFIG=$(grep -rl --include="*.yml" --include="*.yaml" --include="*.properties" \
               -E "resilience4j" "$ROOT_DIR" 2>/dev/null | grep -v "/target/" | head -n 3)

if [ -n "$R4J_CONFIG" ]; then
  cfg_ok "Настройки resilience4j найдены: $(echo "$R4J_CONFIG" | tr '\n' ' ')"
else
  cfg_warn "Настройки resilience4j не найдены — будут использованы значения по умолчанию"
fi

echo ""
if [ "$ERRORS" -ne 0 ]; then
  cfg_err "Проверка Circuit Breaker завершилась с ошибками: $ERRORS"
  exit 1
fi

cfg_ok "Проверка Circuit Breaker пройдена"
exit 0
