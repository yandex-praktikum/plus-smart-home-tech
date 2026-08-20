#!/bin/bash

# Проверки Spring Cloud Config Server. Используются на ветках, где сервер конфигурации
# уже должен существовать: 5-config-server и все последующие.
#
# Что проверяем:
#   1. В проекте есть модуль config-server (Spring Boot приложение с @EnableConfigServer).
#   2. Для каждого сервиса проекта в config-server есть конфигурация.
#   3. Каждый сервис настроен на получение конфигурации из config-server.
#
# Режимы запуска:
#   static  — проверки по исходникам, запущенные сервисы не нужны;
#   runtime — проверки через HTTP API уже запущенного config-server;
#   all     — оба набора (по умолчанию).
#
# Проверка того, что сервисы действительно стартовали с конфигурацией из config-server,
# вынесена в отдельный скрипт check-config-clients.sh (он работает по логам сервисов).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./config-lib.sh
source "${SCRIPT_DIR}/config-lib.sh"

MODE="${1:-all}"
ERRORS=0

fail() {
  cfg_err "$*"
  ERRORS=$((ERRORS + 1))
}

# --------------------------------------------------------------------------------------
# 1. Модуль config-server
# --------------------------------------------------------------------------------------

CONFIG_SERVER_DIR=$(cfg_config_server_dir 2>/dev/null)

check_config_server_module() {
  echo ""
  echo "=== 1. Проверка наличия модуля config-server ==="

  if [ -z "$CONFIG_SERVER_DIR" ]; then
    fail "Модуль config-server не найден. Добавьте Spring Boot модуль с аннотацией @EnableConfigServer."
    return 1
  fi

  cfg_ok "Модуль config-server найден: $CONFIG_SERVER_DIR"

  if grep -rq --include="*.java" --include="*.kt" "@EnableConfigServer" "$CONFIG_SERVER_DIR" 2>/dev/null; then
    cfg_ok "Аннотация @EnableConfigServer на месте"
  else
    fail "В модуле $CONFIG_SERVER_DIR нет аннотации @EnableConfigServer"
  fi

  if cfg_module_has_dependency "$CONFIG_SERVER_DIR" "spring-cloud-config-server"; then
    cfg_ok "Зависимость spring-cloud-config-server подключена"
  else
    fail "В $CONFIG_SERVER_DIR/pom.xml нет зависимости spring-cloud-config-server"
  fi

  local config_files
  config_files=$(cfg_module_config_files "$CONFIG_SERVER_DIR")
  if [ -z "$config_files" ]; then
    fail "У модуля config-server нет файла src/main/resources/application.yml|yaml|properties"
  else
    cfg_info "📄 Конфигурация config-server: $(echo "$config_files" | tr '\n' ' ')"
    if grep -Eq "search-?[Ll]ocations|uri:|native" $config_files 2>/dev/null; then
      cfg_ok "Источник конфигураций (search-locations / git uri) задан"
    else
      cfg_warn "Не удалось найти настройку источника конфигураций в application-файле config-server"
    fi
  fi

  return 0
}

# --------------------------------------------------------------------------------------
# 2. Конфигурации сервисов в config-server (статически, по файлам)
# --------------------------------------------------------------------------------------

# Ищем файлы конфигурации сервиса вне его собственного модуля:
#   <app>.yml | <app>.yaml | <app>.properties | <app>/application.*
find_config_sources() {
  local app=$1 module_dir=$2

  find "$ROOT_DIR" \
       \( -path "*/target/*" -o -path "*/.git/*" -o -path "*/src/test/*" \) -prune -o \
       \( -name "${app}.yml" -o -name "${app}.yaml" -o -name "${app}.properties" \) -print 2>/dev/null

  find "$ROOT_DIR" \
       \( -path "*/target/*" -o -path "*/.git/*" -o -path "*/src/test/*" \) -prune -o \
       -type d -name "$app" -print 2>/dev/null \
    | while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        [ "$(cfg_norm_path "$dir")" = "$module_dir" ] && continue
        find "$dir" -maxdepth 1 -type f \
             \( -name "application*.yml" -o -name "application*.yaml" -o -name "application*.properties" \) 2>/dev/null
      done
}

check_service_configs_static() {
  echo ""
  echo "=== 2. Проверка наличия конфигураций сервисов в config-server (по файлам) ==="

  local module_dir app sources

  while IFS=$'\t' read -r module_dir app; do
    [ -n "$module_dir" ] || continue

    sources=$(find_config_sources "$app" "$module_dir" | grep -v "^${module_dir}/" | sort -u)

    if [ -n "$sources" ]; then
      cfg_ok "$app: найдены файлы конфигурации: $(echo "$sources" | tr '\n' ' ')"
    else
      cfg_warn "$app: файл конфигурации в репозитории не найден (проверка будет выполнена запросом к config-server)"
    fi
  done <<< "$(cfg_required_config_clients)"
}

# --------------------------------------------------------------------------------------
# 3. Сервисы настроены на config-server (статически)
# --------------------------------------------------------------------------------------

check_clients_static() {
  echo ""
  echo "=== 3. Проверка того, что сервисы настроены на config-server ==="

  local module_dir app found=0

  while IFS=$'\t' read -r module_dir app; do
    [ -n "$module_dir" ] || continue
    found=$((found + 1))

    if cfg_is_config_client "$module_dir"; then
      cfg_ok "$app ($module_dir): настроен на получение конфигурации из config-server"
    else
      fail "$app ($module_dir): нет настройки spring.config.import=configserver:... (или spring.cloud.config.uri/discovery)"
    fi

    if ! cfg_module_has_dependency "$module_dir" "spring-cloud-starter-config"; then
      cfg_warn "$app ($module_dir): в pom.xml не найдена зависимость spring-cloud-starter-config"
    fi
  done <<< "$(cfg_required_config_clients)"

  if [ "$found" -eq 0 ]; then
    fail "Не найдено ни одного сервиса — проверять нечего. Убедитесь, что проект собирается и модули на месте."
  fi
}

# --------------------------------------------------------------------------------------
# Runtime: config-server реально отдаёт конфигурацию каждому сервису
# --------------------------------------------------------------------------------------

check_runtime() {
  echo ""
  echo "=== 4. Проверка конфигураций через запущенный config-server ==="

  if ! command -v jq > /dev/null 2>&1; then
    fail "Утилита jq не установлена — не могу проверить ответы config-server"
    return 1
  fi

  local base_url
  base_url=$(cfg_config_server_url)
  cfg_info "🔎 Адрес config-server: $base_url"

  if ! cfg_wait_for_config_server "$base_url"; then
    fail "config-server не отвечает по адресу $base_url"
    return 1
  fi
  cfg_ok "config-server отвечает на запросы"

  local module_dir app response count names
  while IFS=$'\t' read -r module_dir app; do
    [ -n "$module_dir" ] || continue

    response=$(cfg_fetch_service_config "$base_url" "$app")

    if [ -z "$response" ]; then
      fail "$app: config-server не вернул конфигурацию (GET ${base_url}/${app}/${CONFIG_PROFILE})"
      continue
    fi

    count=$(echo "$response" | jq -r '(.propertySources // []) | length' 2>/dev/null)
    if [ -z "$count" ] || ! [ "$count" -gt 0 ] 2>/dev/null; then
      fail "$app: в config-server нет конфигурации для этого сервиса (propertySources пуст)"
      cfg_info "   Ответ: $(echo "$response" | head -c 500)"
      continue
    fi

    names=$(echo "$response" | jq -r '[.propertySources[].name] | join(", ")' 2>/dev/null)
    cfg_ok "$app: конфигурация получена ($count источник(ов): $names)"
  done <<< "$(cfg_required_config_clients)"
}

# --------------------------------------------------------------------------------------

echo "🔧 Проверка Spring Cloud Config (режим: $MODE, ветка: ${BRANCH_NAME:-${GITHUB_HEAD_REF:-${GITHUB_REF##*/}}})"

case "$CONFIG_BRANCH" in
  5-config-server | 6-discovery-server)
    cfg_info "ℹ️  На этом этапе в задании только сервисы телеметрии — микросервисы витрины появляются с этапа 7,"
    cfg_info "   поэтому конфигурация для них не требуется, даже если заготовки модулей уже созданы."
    ;;
esac

case "$MODE" in
  static)
    check_config_server_module
    check_service_configs_static
    check_clients_static
    ;;
  runtime)
    check_runtime
    ;;
  all)
    check_config_server_module
    check_service_configs_static
    check_clients_static
    check_runtime
    ;;
  *)
    cfg_err "Неизвестный режим '$MODE'. Допустимые значения: static, runtime, all."
    exit 2
    ;;
esac

echo ""
if [ "$ERRORS" -ne 0 ]; then
  cfg_err "Проверка config-server завершилась с ошибками: $ERRORS"
  exit 1
fi

cfg_ok "Проверка config-server пройдена"
exit 0
