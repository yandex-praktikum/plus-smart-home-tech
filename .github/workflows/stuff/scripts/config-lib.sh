#!/bin/bash

# Общие функции для проверок Spring Cloud Config Server.
# Подключается через source:
#   source "$(dirname "$0")/config-lib.sh"
#
# Библиотека не делает никаких предположений о том, как студент разложил модули и
# конфигурации по проекту: модули ищутся по pom.xml и аннотациям, а имя приложения —
# по spring.application.name (оно может не совпадать с именем каталога модуля).

ROOT_DIR="${ROOT_DIR:-.}"
LOG_DIR="${LOG_DIR:-./logs}"

EUREKA_PORT=${EUREKA_PORT:-8761}
EUREKA_URL="${EUREKA_URL:-http://localhost:${EUREKA_PORT}/eureka}"

DEFAULT_CONFIG_SERVER_PORT=${DEFAULT_CONFIG_SERVER_PORT:-8888}
CONFIG_PROFILE=${CONFIG_PROFILE:-default}

# Модули инфраструктуры, которые не обязаны быть клиентами config-server.
CONFIG_CLIENT_EXCLUDES=${CONFIG_CLIENT_EXCLUDES:-"config-server discovery-server eureka-server registry-server hub-router tester"}

# Файл со списком запущенных сервисов: <имя приложения>\t<файл лога>\t<имя модуля>
STARTED_SERVICES_FILE="${STARTED_SERVICES_FILE:-${LOG_DIR}/started-services.tsv}"

# --------------------------------------------------------------------------------------
# Вспомогательные функции вывода
# --------------------------------------------------------------------------------------

cfg_info() { echo "$*"; }
cfg_ok()   { echo "✅ $*"; }
cfg_warn() { echo "⚠️  $*"; }
cfg_err()  { echo "❌ $*"; }

# --------------------------------------------------------------------------------------
# Разбор конфигураций (yaml / properties) без внешних зависимостей
# --------------------------------------------------------------------------------------

# Приводит простой YAML к плоскому виду "a.b.c=value".
# Элементы списков пропускаются — для проверок достаточно скалярных значений.
cfg_flatten_yaml() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    {
      line = $0
      sub(/\r$/, "", line)

      probe = trim(line)
      if (probe == "" || probe ~ /^#/ || probe ~ /^-/) next
      if (index(line, ":") == 0) next

      match(line, /^[ ]*/)
      indent = RLENGTH

      rest = line
      sub(/^[ ]*/, "", rest)

      pos = index(rest, ":")
      key = trim(substr(rest, 1, pos - 1))
      val = trim(substr(rest, pos + 1))

      gsub("[\"\047]", "", key)
      if (key == "") next

      # значение вида "value # комментарий"
      if (val ~ /[ \t]#/) sub(/[ \t]+#.*$/, "", val)
      val = trim(val)
      gsub("^[\"\047]", "", val)
      gsub("[\"\047]$", "", val)

      while (top > 0 && indents[top] >= indent) top--
      top++
      indents[top] = indent
      names[top] = key

      if (val != "") {
        full = ""
        for (i = 1; i <= top; i++) full = (full == "" ? names[i] : full "." names[i])
        print full "=" val
      }
    }
  ' "$1" 2>/dev/null
}

cfg_flatten_properties() {
  sed -e 's/\r$//' "$1" 2>/dev/null \
    | grep -Ev '^[[:space:]]*([#!]|$)' \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*[:=][[:space:]]*/=/' \
    | sed -E 's/^([^=]+)=(.*)$/\1=\2/'
}

cfg_flatten_file() {
  local file=$1
  [ -f "$file" ] || return 0

  case "$file" in
    *.properties) cfg_flatten_properties "$file" ;;
    *)            cfg_flatten_yaml "$file" ;;
  esac
}

# cfg_get <файл> <ключ> — значение свойства или пустая строка
cfg_get() {
  cfg_flatten_file "$1" | grep -m 1 -E "^$(echo "$2" | sed 's/\./\\./g')=" | cut -d= -f2-
}

# --------------------------------------------------------------------------------------
# Поиск модулей
# --------------------------------------------------------------------------------------

cfg_norm_path() {
  local path=$1
  path=${path#./}
  echo "${path%/}"
}

# Каталог maven-модуля, которому принадлежит файл
cfg_module_root_of() {
  local dir
  dir=$(dirname "$1")

  while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/pom.xml" ]; then
      cfg_norm_path "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done

  return 1
}

# Каталоги всех модулей, содержащих Spring Boot приложение
cfg_spring_boot_modules() {
  find "$ROOT_DIR" -name pom.xml -not -path "*/target/*" -not -path "*/.git/*" 2>/dev/null \
    | while IFS= read -r pom; do
        local dir
        dir=$(dirname "$pom")
        [ -d "$dir/src/main" ] || continue
        if grep -rq --include="*.java" --include="*.kt" "@SpringBootApplication" "$dir/src/main" 2>/dev/null; then
          cfg_norm_path "$dir"
        fi
      done | sort -u
}

# Каталог модуля config-server: сначала по аннотации, затем по имени каталога/artifactId
cfg_config_server_dir() {
  local file dir

  file=$(grep -rl --include="*.java" --include="*.kt" "@EnableConfigServer" "$ROOT_DIR" 2>/dev/null \
         | grep -v "/target/" | head -n 1)
  if [ -n "$file" ]; then
    cfg_module_root_of "$file" && return 0
  fi

  dir=$(find "$ROOT_DIR" -type d -name "config-server" -not -path "*/target/*" -not -path "*/.git/*" 2>/dev/null | head -n 1)
  if [ -n "$dir" ] && [ -f "$dir/pom.xml" ]; then
    cfg_norm_path "$dir"
    return 0
  fi

  return 1
}

# Каталог модуля по имени каталога или artifactId
cfg_module_dir_by_name() {
  local name=$1 dir pom

  dir=$(find "$ROOT_DIR" -type d -name "$name" -not -path "*/target/*" -not -path "*/.git/*" 2>/dev/null | head -n 1)
  if [ -n "$dir" ] && [ -f "$dir/pom.xml" ]; then
    cfg_norm_path "$dir"
    return 0
  fi

  pom=$(grep -rl --include="pom.xml" "<artifactId>${name}</artifactId>" "$ROOT_DIR" 2>/dev/null \
        | grep -v "/target/" | head -n 1)
  if [ -n "$pom" ]; then
    cfg_norm_path "$(dirname "$pom")"
    return 0
  fi

  return 1
}

# Основные файлы конфигурации модуля
cfg_module_config_files() {
  local dir=$1 file
  for file in "$dir"/src/main/resources/application.yml \
              "$dir"/src/main/resources/application.yaml \
              "$dir"/src/main/resources/application.properties; do
    [ -f "$file" ] && echo "$file"
  done
  return 0
}

cfg_module_artifact_id() {
  local pom="$1/pom.xml"

  [ -f "$pom" ] || { basename "$1"; return 0; }

  awk '
    /<parent>/  { parent = 1 }
    /<\/parent>/ { parent = 0; next }
    !parent && /<artifactId>/ {
      line = $0
      sub(/.*<artifactId>/, "", line)
      sub(/<\/artifactId>.*/, "", line)
      gsub(/[ \t\r]/, "", line)
      if (line != "") { print line; exit }
    }
  ' "$pom"
}

# spring.application.name модуля (fallback: artifactId, затем имя каталога)
cfg_module_app_name() {
  local dir=$1 file name=""

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    name=$(cfg_get "$file" "spring.application.name")
    [ -n "$name" ] && break
  done <<< "$(cfg_module_config_files "$dir")"

  if [ -z "$name" ]; then
    name=$(cfg_module_artifact_id "$dir")
  fi
  if [ -z "$name" ]; then
    name=$(basename "$dir")
  fi

  echo "$name"
}

cfg_module_server_port() {
  local dir=$1 file port=""

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    port=$(cfg_get "$file" "server.port")
    [ -n "$port" ] && break
  done <<< "$(cfg_module_config_files "$dir")"

  echo "$port"
}

# Модуль настроен на получение конфигурации из config-server?
cfg_is_config_client() {
  local dir=$1 file value

  while IFS= read -r file; do
    [ -n "$file" ] || continue

    grep -q "configserver:" "$file" 2>/dev/null && return 0

    value=$(cfg_get "$file" "spring.cloud.config.uri")
    [ -n "$value" ] && return 0

    value=$(cfg_get "$file" "spring.cloud.config.discovery.enabled")
    [ "$value" = "true" ] && return 0
  done <<< "$(cfg_module_config_files "$dir")"

  return 1
}

cfg_module_has_dependency() {
  local dir=$1 artifact=$2
  local current=$dir

  # Зависимость может быть объявлена как в pom модуля, так и в родительском pom
  while [ -n "$current" ] && [ "$current" != "." ] && [ "$current" != "/" ]; do
    if [ -f "$current/pom.xml" ] && grep -q "<artifactId>${artifact}</artifactId>" "$current/pom.xml" 2>/dev/null; then
      return 0
    fi
    current=$(dirname "$current")
  done

  [ -f "pom.xml" ] && grep -q "<artifactId>${artifact}</artifactId>" "pom.xml" 2>/dev/null
}

# Сервисы, которые обязаны быть клиентами config-server.
# Формат вывода: <каталог модуля>\t<имя приложения>
cfg_required_config_clients() {
  local cs_dir dir base name

  cs_dir=$(cfg_config_server_dir 2>/dev/null)

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -n "$cs_dir" ] && [ "$dir" = "$cs_dir" ] && continue

    base=$(basename "$dir")
    case " $CONFIG_CLIENT_EXCLUDES " in
      *" $base "*) continue ;;
    esac

    name=$(cfg_module_app_name "$dir")
    printf '%s\t%s\n' "$dir" "$name"
  done <<< "$(cfg_spring_boot_modules)"
}

# --------------------------------------------------------------------------------------
# Работа с запущенным config-server
# --------------------------------------------------------------------------------------

cfg_eureka_home_page() {
  local app=$1

  command -v jq > /dev/null 2>&1 || return 1

  curl -s -H "Accept: application/json" "${EUREKA_URL}/apps/${app}" 2>/dev/null \
    | jq -r '.application.instance | if type=="array" then .[0] else . end | .homePageUrl // empty' 2>/dev/null
}

# Базовый адрес config-server.
# Порт берём из конфигурации модуля; если он динамический (0) — ищем адрес в Eureka.
cfg_config_server_url() {
  local dir port app_name url

  if [ -n "${CONFIG_SERVER_URL:-}" ]; then
    echo "${CONFIG_SERVER_URL%/}"
    return 0
  fi

  dir=$(cfg_config_server_dir 2>/dev/null)
  if [ -n "$dir" ]; then
    port=$(cfg_module_server_port "$dir")
    app_name=$(cfg_module_app_name "$dir")
  fi

  if [ -n "$port" ] && [ "$port" != "0" ]; then
    echo "http://localhost:${port}"
    return 0
  fi

  url=$(cfg_eureka_home_page "${app_name:-config-server}")
  if [ -n "$url" ]; then
    echo "${url%/}"
    return 0
  fi

  echo "http://localhost:${DEFAULT_CONFIG_SERVER_PORT}"
}

# Ждём, пока config-server начнёт отвечать. По умолчанию до 90 секунд.
cfg_wait_for_config_server() {
  local base_url=$1
  local attempts=${2:-${CONFIG_SERVER_WAIT_ATTEMPTS:-18}}
  local delay=${3:-${CONFIG_SERVER_WAIT_DELAY:-5}}
  local i code

  for ((i = 1; i <= attempts; i++)); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${base_url}/application/${CONFIG_PROFILE}" 2>/dev/null)
    if [ "$code" = "200" ]; then
      return 0
    fi
    cfg_info "⏳ Ждём config-server на ${base_url}... ($i/$attempts, http=$code)"
    sleep "$delay"
  done

  return 1
}

# Конфигурация приложения с config-server (JSON) или пустая строка
cfg_fetch_service_config() {
  local base_url=$1 app=$2
  curl -s --connect-timeout 10 -H "Accept: application/json" "${base_url}/${app}/${CONFIG_PROFILE}" 2>/dev/null
}
