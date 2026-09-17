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

# --------------------------------------------------------------------------------------
# Дополнительные экземпляры сервиса
#
# Нужны для проверки балансировки нагрузки: gateway должен распределять запросы
# между всеми экземплярами сервиса, зарегистрированными в реестре.
# --------------------------------------------------------------------------------------

# Ключ, под которым дополнительный экземпляр записывается в $SERVICE_COMMANDS_FILE.
# Отличается от имени модуля, поэтому svc_stop/svc_start основного экземпляра
# продолжают работать с оригинальной записью.
svc_replica_key() {
  echo "$1-$2"
}

# Идентификатор экземпляра в Eureka задаём явно: иначе при остановке реплики
# пришлось бы снимать с регистрации все экземпляры сервиса, включая живые.
svc_replica_instance_id() {
  echo "replica-$1-$2"
}

# Запускает ещё один экземпляр уже работающего сервиса той же командой.
# Порт остаётся случайным (server.port: 0), поэтому экземпляры не конфликтуют,
# а базу данных они делят намеренно — это одно и то же приложение.
svc_start_replica() {
  local module=$1
  local suffix=${2:-2}
  local command log_file replica_log instance_id key pid

  command=$(svc_command "$module")
  log_file=$(svc_log "$module")

  if [ -z "$command" ]; then
    echo "❌ Не найдена команда запуска сервиса $module"
    return 1
  fi

  key=$(svc_replica_key "$module" "$suffix")
  instance_id=$(svc_replica_instance_id "$module" "$suffix")
  replica_log="${log_file%.log}-${suffix}.log"

  # Экземпляры не должны писать в общие файлы: подменяем и лог приложения,
  # и префикс access-лога — по нему считается распределение запросов.
  command=${command//--logging.file.name=\"${log_file}\"/--logging.file.name=\"${replica_log}\"}
  command=${command//--server.tomcat.accesslog.prefix=${module} /--server.tomcat.accesslog.prefix=${key} }
  command="$command --eureka.instance.instance-id=${instance_id}"

  echo "🚀 Запускаем дополнительный экземпляр сервиса $module ($key)..."
  eval "nohup $command > \"$replica_log\" 2>&1 &"
  pid=$!

  svc_record "$key" "$(svc_app_name "$module")" "$pid" "$replica_log" "$command"

  sleep 15
  if ! svc_is_running "$pid"; then
    echo "❌ Дополнительный экземпляр $key не запустился. Последние строки лога:"
    tail -n 40 "$replica_log"
    return 1
  fi

  echo "✅ Дополнительный экземпляр $key запущен (pid=$pid)"
}

# Останавливает дополнительный экземпляр, снимая с регистрации только его.
svc_stop_replica() {
  local module=$1
  local suffix=${2:-2}
  local key app pid i

  key=$(svc_replica_key "$module" "$suffix")
  pid=$(svc_pid "$key")
  app=$(svc_app_name "$key")

  if [ -z "$pid" ]; then
    echo "ℹ️  Дополнительный экземпляр $key не запускался — останавливать нечего"
    return 0
  fi

  echo "🛑 Останавливаем дополнительный экземпляр $key (pid=$pid)..."
  curl -s -X DELETE "${EUREKA_URL}/apps/${app}/$(svc_replica_instance_id "$module" "$suffix")" > /dev/null 2>&1

  kill "$pid" 2>/dev/null

  for ((i = 0; i < 20; i++)); do
    if ! svc_is_running "$pid"; then
      echo "✅ Дополнительный экземпляр $key остановлен"
      return 0
    fi
    sleep 1
  done

  echo "⚠️  Экземпляр $key не завершился штатно, отправляем SIGKILL"
  kill -9 "$pid" 2>/dev/null
  sleep 2
  return 0
}

# Сколько экземпляров сервиса зарегистрировано в Eureka со статусом UP
svc_instance_count() {
  local app=$1

  command -v jq > /dev/null 2>&1 || { echo 0; return 0; }

  curl -s -H "Accept: application/json" "${EUREKA_URL}/apps/${app}" 2>/dev/null \
    | jq -r '[.application.instance // [] | if type=="array" then .[] else . end
             | select(.status == "UP")] | length' 2>/dev/null \
    || echo 0
}

# Ждём, пока в реестре появится нужное число живых экземпляров сервиса
svc_wait_instances() {
  local app=$1
  local expected=$2
  local attempts=${3:-24}
  local i count

  for ((i = 1; i <= attempts; i++)); do
    count=$(svc_instance_count "$app")
    if [ "${count:-0}" -ge "$expected" ]; then
      echo "✅ В Eureka зарегистрировано экземпляров $app: $count"
      return 0
    fi
    echo "⏳ Ждём регистрации экземпляров $app: сейчас ${count:-0}, нужно $expected... ($i/$attempts)"
    sleep 5
  done

  echo "❌ В Eureka так и не появилось $expected экземпляров сервиса $app"
  return 1
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
