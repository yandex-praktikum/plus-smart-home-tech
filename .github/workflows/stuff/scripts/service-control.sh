#!/bin/bash

# Управление запущенными сервисами: остановка, повторный запуск, ожидание готовности.
# Нужно для проверок отказоустойчивости (Circuit Breaker), где зависимость сервиса
# намеренно «гасят», а затем поднимают обратно.
#
# Данные о запущенных сервисах пишет start-services.sh в $SERVICE_COMMANDS_FILE:
#   <модуль>\t<имя приложения>\t<pid>\t<файл лога>\t<команда запуска>

SVC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config-lib.sh
source "${SVC_LIB_DIR}/config-lib.sh"

SERVICE_COMMANDS_FILE="${SERVICE_COMMANDS_FILE:-${LOG_DIR}/service-commands.tsv}"

svc_record() {
  local module=$1 app=$2 pid=$3 log_file=$4 command=$5

  mkdir -p "$(dirname "$SERVICE_COMMANDS_FILE")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$module" "$app" "$pid" "$log_file" "$command" >> "$SERVICE_COMMANDS_FILE"
}

svc_line() {
  local module=$1
  [ -f "$SERVICE_COMMANDS_FILE" ] || return 1
  grep -m 1 -P "^${module}\t" "$SERVICE_COMMANDS_FILE" 2>/dev/null \
    || awk -F'\t' -v m="$module" '$1 == m { print; exit }' "$SERVICE_COMMANDS_FILE"
}

svc_field() {
  local module=$1 index=$2
  svc_line "$module" | cut -f "$index"
}

svc_app_name() { svc_field "$1" 2; }
svc_pid()      { svc_field "$1" 3; }
svc_log()      { svc_field "$1" 4; }
svc_command()  { svc_field "$1" 5; }

svc_set_pid() {
  local module=$1 pid=$2
  local tmp="${SERVICE_COMMANDS_FILE}.tmp"

  awk -F'\t' -v OFS='\t' -v m="$module" -v p="$pid" '$1 == m { $3 = p } { print }' \
      "$SERVICE_COMMANDS_FILE" > "$tmp" && mv "$tmp" "$SERVICE_COMMANDS_FILE"
}

# Снимаем регистрацию в Eureka, чтобы соседние сервисы не ходили на мёртвый инстанс
# дольше, чем длится аренда, и поведение теста было предсказуемым.
svc_deregister_from_eureka() {
  local app=$1
  local instances instance

  command -v jq > /dev/null 2>&1 || return 0

  instances=$(curl -s -H "Accept: application/json" "${EUREKA_URL}/apps/${app}" 2>/dev/null \
    | jq -r '.application.instance // [] | if type=="array" then .[] else . end | .instanceId // empty' 2>/dev/null)

  while IFS= read -r instance; do
    [ -n "$instance" ] || continue
    curl -s -X DELETE "${EUREKA_URL}/apps/${app}/${instance}" > /dev/null 2>&1
    echo "   🗑️  Снята регистрация ${app}/${instance} в Eureka"
  done <<< "$instances"
}

svc_is_running() {
  local pid=$1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

svc_stop() {
  local module=$1
  local pid app i

  pid=$(svc_pid "$module")
  app=$(svc_app_name "$module")

  if [ -z "$pid" ]; then
    echo "❌ Сервис $module не найден в $SERVICE_COMMANDS_FILE"
    return 1
  fi

  echo "🛑 Останавливаем сервис $module (pid=$pid)..."
  svc_deregister_from_eureka "$app"

  kill "$pid" 2>/dev/null

  for ((i = 0; i < 20; i++)); do
    if ! svc_is_running "$pid"; then
      echo "✅ Сервис $module остановлен"
      return 0
    fi
    sleep 1
  done

  echo "⚠️  Сервис $module не завершился штатно, отправляем SIGKILL"
  kill -9 "$pid" 2>/dev/null
  sleep 2
  return 0
}

svc_start() {
  local module=$1
  local command log_file pid

  command=$(svc_command "$module")
  log_file=$(svc_log "$module")

  if [ -z "$command" ]; then
    echo "❌ Не найдена команда запуска сервиса $module"
    return 1
  fi

  echo "🚀 Запускаем сервис $module заново..."
  eval "nohup $command >> \"$log_file\" 2>&1 &"
  pid=$!
  svc_set_pid "$module" "$pid"

  sleep 10
  if ! svc_is_running "$pid"; then
    echo "❌ Сервис $module не запустился. Последние строки лога:"
    tail -n 40 "$log_file"
    return 1
  fi

  echo "✅ Сервис $module запущен (pid=$pid)"
}

# Ждём, пока сервис снова появится в Eureka со статусом UP
svc_wait_registered() {
  local module=$1
  local attempts=${2:-24}
  local app i

  app=$(svc_app_name "$module")
  command -v jq > /dev/null 2>&1 || { sleep 20; return 0; }

  for ((i = 1; i <= attempts; i++)); do
    if curl -s -H "Accept: application/json" "${EUREKA_URL}/apps/${app}" 2>/dev/null \
         | jq -e '[.application.instance // [] | if type=="array" then .[] else . end | select(.status == "UP")] | length > 0' > /dev/null 2>&1; then
      echo "✅ Сервис $app снова зарегистрирован в Eureka"
      return 0
    fi
    echo "⏳ Ждём регистрации $app в Eureka... ($i/$attempts)"
    sleep 5
  done

  echo "❌ Сервис $app не зарегистрировался в Eureka после перезапуска"
  return 1
}
