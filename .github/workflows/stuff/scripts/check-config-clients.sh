#!/bin/bash

# Проверка того, что запущенные сервисы действительно получили конфигурацию
# из config-server, а не только из собственных application-файлов.
#
# Сервисы запускаются с параметром --logging.level.org.springframework.cloud.config=DEBUG
# (аргумент командной строки имеет наивысший приоритет и не может быть переопределён
# конфигурацией с сервера), поэтому в логе гарантированно появляются сообщения
# Spring Cloud Config Client.
#
# Список запущенных сервисов пишет start-services.sh в $STARTED_SERVICES_FILE
# в формате: <имя приложения>\t<файл лога>\t<имя модуля>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./config-lib.sh
source "${SCRIPT_DIR}/config-lib.sh"

ERRORS=0

fail() {
  cfg_err "$*"
  ERRORS=$((ERRORS + 1))
}

# Сообщения Spring Cloud Config Client, подтверждающие получение конфигурации
SUCCESS_PATTERNS='Fetching config from server at|Located environment: name=|Located property source|Located property sources|configserver:http'

# Сообщения о неудачной попытке получить конфигурацию
FAILURE_PATTERNS='Could not locate PropertySource|ConfigClientFailFastException|Could not resolve placeholder .spring.cloud.config|No spring.config.import property has been defined'

echo "🔧 Проверка того, что сервисы работают с конфигурацией из config-server"

if [ ! -f "$STARTED_SERVICES_FILE" ]; then
  cfg_err "Не найден список запущенных сервисов: $STARTED_SERVICES_FILE"
  cfg_err "Сервисы не были запущены — проверить получение конфигурации невозможно."
  exit 1
fi

CHECKED=0

while IFS=$'\t' read -r app log_file module; do
  [ -n "$app" ] || continue

  echo ""
  echo "--- $app (${module:-?}) ---"

  if [ ! -f "$log_file" ]; then
    fail "$app: не найден лог сервиса ($log_file)"
    continue
  fi

  CHECKED=$((CHECKED + 1))

  if grep -Eq "$FAILURE_PATTERNS" "$log_file"; then
    fail "$app: в логе есть ошибки получения конфигурации из config-server:"
    grep -E "$FAILURE_PATTERNS" "$log_file" | head -n 5 | sed 's/^/    /'
    continue
  fi

  if ! grep -Eq "$SUCCESS_PATTERNS" "$log_file"; then
    fail "$app: в логе нет признаков загрузки конфигурации из config-server"
    cfg_info "    Ожидались сообщения вида 'Fetching config from server at ...' / 'Located environment: name=$app'"
    cfg_info "    Убедитесь, что в application.yml сервиса задан spring.config.import: configserver:..."
    continue
  fi

  cfg_ok "$app: конфигурация загружена из config-server"
  grep -E "$SUCCESS_PATTERNS" "$log_file" | head -n 3 | sed 's/^/    /'

  # Проверяем, что сервер отдал окружение именно для этого приложения
  if grep -q "Located environment" "$log_file" && ! grep -q "Located environment: name=${app}" "$log_file"; then
    cfg_warn "$app: config-server вернул окружение для другого имени приложения:"
    grep "Located environment" "$log_file" | head -n 2 | sed 's/^/    /'
  fi
done < "$STARTED_SERVICES_FILE"

echo ""

if [ "$CHECKED" -eq 0 ]; then
  cfg_err "Не удалось проверить ни одного сервиса"
  exit 1
fi

if [ "$ERRORS" -ne 0 ]; then
  cfg_err "Сервисы, работающие с конфигурацией из config-server: обнаружено ошибок — $ERRORS"
  exit 1
fi

cfg_ok "Все запущенные сервисы ($CHECKED) получили конфигурацию из config-server"
exit 0
