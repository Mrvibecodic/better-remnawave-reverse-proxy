#!/bin/bash
# Module: Alternative Xray core for Remnawave Node
# better-fork: монтирует свой бинарь xray в контейнер ноды (/usr/local/bin/xray).
# Источник по умолчанию — форк Jolymmiles/Xray-core, версия закреплена.

XRAY_ALT_REPO="Jolymmiles/Xray-core"
# better-fork: версия НЕ закреплена — берём последний релиз репозитория.
# Пин ниже используется только как запасной вариант, если API GitHub недоступен.
XRAY_ALT_FALLBACK_VERSION="v26.7.29"
XRAY_ALT_VERSION=""
XRAY_ALT_FILE="xray-core"
XRAY_ALT_MOUNT="./${XRAY_ALT_FILE}:/usr/local/bin/xray"

# Каталог, где лежит docker-compose.yml ноды
xray_core_dir() {
    if [ -f "/opt/remnanode/docker-compose.yml" ] && grep -q "remnanode:" /opt/remnanode/docker-compose.yml 2>/dev/null; then
        echo "/opt/remnanode"
    elif [ -f "/opt/remnawave/docker-compose.yml" ] && grep -q "remnanode:" /opt/remnawave/docker-compose.yml 2>/dev/null; then
        echo "/opt/remnawave"
    else
        return 1
    fi
    return 0
}

# Последний релиз форка (stdout = тег; код возврата 1 = сработал фолбэк)
xray_core_latest_version() {
    local v
    v=$(curl -fsSL --connect-timeout 8 --max-time 15 \
        "https://api.github.com/repos/${XRAY_ALT_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)
    if [ -n "$v" ] && [ "$v" != "null" ]; then
        echo "$v"
        return 0
    fi
    echo "$XRAY_ALT_FALLBACK_VERSION"
    return 1
}

# Определить версию и сообщить пользователю, какая именно пойдёт в ноду
xray_core_resolve_version() {
    echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_RESOLVING]}${COLOR_RESET}"
    if XRAY_ALT_VERSION=$(xray_core_latest_version); then
        printf "${COLOR_GREEN}${LANG[XRAY_CORE_LATEST_FOUND]}${COLOR_RESET}\n" "$XRAY_ALT_VERSION"
    else
        printf "${COLOR_YELLOW}${LANG[XRAY_CORE_LATEST_FAILED]}${COLOR_RESET}\n" "$XRAY_ALT_VERSION"
    fi
    return 0
}

# Имя ассета релиза под текущую архитектуру
xray_core_asset() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "Xray-linux-64.zip" ;;
        aarch64|arm64)  echo "Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7)   echo "Xray-linux-arm32-v7a.zip" ;;
        armv6l)         echo "Xray-linux-arm32-v6.zip" ;;
        i386|i686)      echo "Xray-linux-32.zip" ;;
        *)              return 1 ;;
    esac
    return 0
}

# better-fork: бэкап docker-compose.yml перед любой правкой (и установка, и откат).
# Хранится рядом с файлом, с меткой времени; последние 5 копий остаются, старые чистятся.
xray_core_backup_compose() {
    local compose="$1"
    [ -f "$compose" ] || return 1
    local stamp; stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)
    local bak="${compose}.bak-${stamp}"
    if cp -p "$compose" "$bak" 2>/dev/null; then
        XRAY_CORE_LAST_BACKUP="$bak"
        printf "${COLOR_GRAY}${LANG[XRAY_CORE_BACKUP_MADE]}${COLOR_RESET}\n" "$bak"
        # оставляем только 5 последних бэкапов
        ls -1t "${compose}".bak-* 2>/dev/null | tail -n +6 | while IFS= read -r old; do
            rm -f "$old" 2>/dev/null
        done
        return 0
    fi
    echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_BACKUP_FAILED]}${COLOR_RESET}" >&2
    return 1
}

# better-fork: проверка, что compose остался валидным. Возвращает 0 = валиден, 1 = сломан,
# 2 = проверить нечем (нет ни docker compose, ни python-yaml).
xray_core_compose_valid() {
    local compose="$1"
    local dir; dir=$(dirname "$compose")
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ( cd "$dir" && docker compose config -q ) >/dev/null 2>&1 && return 0 || return 1
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
        python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$compose" >/dev/null 2>&1 && return 0 || return 1
    fi
    return 2
}

# Проверить файл после правки и откатить из бэкапа, если мы его сломали
xray_core_verify_or_rollback() {
    local compose="$1"
    local was_valid="$2"     # был ли файл валиден ДО правки
    xray_core_compose_valid "$compose"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        echo -e "${COLOR_GREEN}${LANG[XRAY_CORE_COMPOSE_OK]}${COLOR_RESET}"
        return 0
    fi
    if [ "$rc" -eq 2 ]; then
        echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_COMPOSE_UNCHECKED]}${COLOR_RESET}"
        return 0
    fi
    # файл невалиден: если до нас он был в порядке — виноваты мы, откатываем
    if [ "$was_valid" = "0" ] && [ -n "$XRAY_CORE_LAST_BACKUP" ] && [ -f "$XRAY_CORE_LAST_BACKUP" ]; then
        cp -p "$XRAY_CORE_LAST_BACKUP" "$compose"
        printf "${COLOR_RED}${LANG[XRAY_CORE_COMPOSE_ROLLED_BACK]}${COLOR_RESET}\n" "$XRAY_CORE_LAST_BACKUP"
        return 1
    fi
    echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_COMPOSE_WAS_BROKEN]}${COLOR_RESET}"
    return 0
}

# Добавить монтирование бинаря в сервис remnanode
xray_core_add_mount() {
    local compose="$1"
    if grep -q "$XRAY_ALT_MOUNT" "$compose"; then
        return 0
    fi

    # better-fork: отступы берём ИЗ САМОГО ФАЙЛА. Compose, скопированный из панели, использует
    # 4/8/12 пробела, наш генератор — 2/4/6; жёстко заданный отступ ломал YAML или склеивал
    # строки списка. Границы сервиса определяются по отступу (вложенный depends_on не мешает).
    local info
    info=$(awk '
        function ind(s){ match(s, /^[[:space:]]*/); return RLENGTH }
        {
            if (!in_node && $0 ~ /^[[:space:]]*remnanode:[[:space:]]*$/) { node=ind($0); in_node=1; next }
            if (in_node) {
                if ($0 ~ /^[[:space:]]*$/) next
                i = ind($0)
                if (i <= node) { in_node=0; next }
                if (prop == 0) prop = i
                if (invol && $0 ~ /^[[:space:]]*-/ && i >= volind) { if (item == 0) item = i; next }
                if (invol && i <= volind) invol=0
                if (!hasvol && $0 ~ /^[[:space:]]*volumes:[[:space:]]*$/) { hasvol=1; volind=i; invol=1 }
            }
        }
        END { printf "%d %d %d %d %d", node+0, prop+0, hasvol+0, volind+0, item+0 }
    ' "$compose")
    local node_ind prop_ind has_vol vol_ind item_ind
    read -r node_ind prop_ind has_vol vol_ind item_ind <<< "$info"

    if [ "${node_ind:-0}" -eq 0 ] && ! grep -q "remnanode:" "$compose"; then
        return 1
    fi
    [ "${prop_ind:-0}" -gt 0 ] || prop_ind=$((node_ind + 2))

    xray_core_compose_valid "$compose"; local was_valid=$?
    xray_core_backup_compose "$compose"

    local tmp; tmp=$(mktemp) || return 1
    if [ "${has_vol:-0}" -eq 1 ]; then
        # добавляем элемент в существующий список с ЕГО отступом
        [ "${item_ind:-0}" -gt 0 ] || item_ind=$((vol_ind + 2))
        awk -v mount="$XRAY_ALT_MOUNT" -v volind="$vol_ind" -v itemind="$item_ind" '
            function ind(s){ match(s, /^[[:space:]]*/); return RLENGTH }
            {
                line = $0
                if (!in_node && line ~ /^[[:space:]]*remnanode:[[:space:]]*$/) { node=ind(line); in_node=1; print line; next }
                if (in_node && !done && line ~ /^[[:space:]]*[^[:space:]]/ && ind(line) <= node) in_node=0
                print line
                if (in_node && !done && line ~ /^[[:space:]]*volumes:[[:space:]]*$/ && ind(line) == volind) {
                    pad = sprintf("%*s", itemind, ""); print pad "- " mount; done=1
                }
            }
        ' "$compose" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        # секции volumes нет — создаём её на уровне остальных свойств сервиса
        awk -v mount="$XRAY_ALT_MOUNT" -v propind="$prop_ind" '
            {
                print
                if (!done && $0 ~ /^[[:space:]]*remnanode:[[:space:]]*$/) {
                    padk = sprintf("%*s", propind, "");
                    padv = sprintf("%*s", propind + 2, "");
                    print padk "volumes:"; print padv "- " mount; done=1
                }
            }
        ' "$compose" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi

    grep -q "$XRAY_ALT_MOUNT" "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$compose"

    xray_core_verify_or_rollback "$compose" "$was_valid" || return 1
    return 0
}

xray_core_remove_mount() {
    local compose="$1"
    [ -f "$compose" ] || return 1
    if grep -q "$XRAY_ALT_MOUNT" "$compose"; then
        xray_core_compose_valid "$compose"; local was_valid=$?
        xray_core_backup_compose "$compose"
        sed -i "\|$XRAY_ALT_MOUNT|d" "$compose"
        xray_core_verify_or_rollback "$compose" "$was_valid" || return 1
    fi
    return 0
}

# Скачать бинарь с проверкой SHA256 из .dgst
xray_core_download() {
    local dir="$1"
    local asset; asset=$(xray_core_asset) || {
        printf "${COLOR_RED}${LANG[XRAY_CORE_ARCH_UNSUPPORTED]}${COLOR_RESET}\n" "$(uname -m)" >&2
        return 1
    }
    local base="https://github.com/${XRAY_ALT_REPO}/releases/download/${XRAY_ALT_VERSION}"
    local tmpd; tmpd=$(mktemp -d)

    printf "${COLOR_YELLOW}${LANG[XRAY_CORE_DOWNLOADING]}${COLOR_RESET}\n" "$XRAY_ALT_VERSION" "$asset"
    if ! curl -fsSL --connect-timeout 15 --max-time 300 -o "$tmpd/core.zip" "$base/$asset"; then
        echo -e "${COLOR_RED}${LANG[XRAY_CORE_DOWNLOAD_FAILED]}${COLOR_RESET}" >&2
        rm -rf "$tmpd"; return 1
    fi

    # проверка контрольной суммы (SHA2-256 из .dgst)
    if curl -fsSL --connect-timeout 15 --max-time 60 -o "$tmpd/core.dgst" "$base/${asset}.dgst"; then
        local want have
        want=$(grep -i "^SHA2-256=" "$tmpd/core.dgst" | head -n1 | tr -d ' ' | cut -d'=' -f2)
        have=$(sha256sum "$tmpd/core.zip" | cut -d' ' -f1)
        if [ -n "$want" ] && [ "$want" != "$have" ]; then
            echo -e "${COLOR_RED}${LANG[XRAY_CORE_CHECKSUM_FAILED]}${COLOR_RESET}" >&2
            rm -rf "$tmpd"; return 1
        fi
        [ -n "$want" ] && echo -e "${COLOR_GREEN}${LANG[XRAY_CORE_CHECKSUM_OK]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_CHECKSUM_SKIP]}${COLOR_RESET}"
    fi

    if ! unzip -qo "$tmpd/core.zip" xray -d "$tmpd"; then
        echo -e "${COLOR_RED}${LANG[XRAY_CORE_UNPACK_FAILED]}${COLOR_RESET}" >&2
        rm -rf "$tmpd"; return 1
    fi
    if ! head -c 4 "$tmpd/xray" | grep -q "ELF"; then
        echo -e "${COLOR_RED}${LANG[XRAY_CORE_UNPACK_FAILED]}${COLOR_RESET}" >&2
        rm -rf "$tmpd"; return 1
    fi

    install -m 744 "$tmpd/xray" "$dir/$XRAY_ALT_FILE" || { rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"
    return 0
}

# Основная установка альтернативного ядра (может вызываться из установщика ноды)
install_alt_xray_core() {
    local dir="${1:-}"
    if [ -z "$dir" ]; then
        dir=$(xray_core_dir) || {
            echo -e "${COLOR_RED}${LANG[XRAY_CORE_NO_NODE]}${COLOR_RESET}" >&2
            return 1
        }
    fi
    local compose="$dir/docker-compose.yml"
    [ -f "$compose" ] || { echo -e "${COLOR_RED}${LANG[XRAY_CORE_NO_NODE]}${COLOR_RESET}" >&2; return 1; }

    [ -n "$XRAY_ALT_VERSION" ] || xray_core_resolve_version

    xray_core_download "$dir" || return 1
    if ! xray_core_add_mount "$compose"; then
        echo -e "${COLOR_RED}${LANG[XRAY_CORE_MOUNT_FAILED]}${COLOR_RESET}" >&2
        return 1
    fi
    printf "${COLOR_GREEN}${LANG[XRAY_CORE_INSTALLED]}${COLOR_RESET}\n" "$XRAY_ALT_VERSION" "$dir/$XRAY_ALT_FILE"
    return 0
}

# Вернуть штатное ядро из образа
restore_bundled_xray_core() {
    local dir; dir=$(xray_core_dir) || {
        echo -e "${COLOR_RED}${LANG[XRAY_CORE_NO_NODE]}${COLOR_RESET}" >&2
        return 1
    }
    xray_core_remove_mount "$dir/docker-compose.yml"
    rm -f "$dir/$XRAY_ALT_FILE"
    echo -e "${COLOR_GREEN}${LANG[XRAY_CORE_RESTORED]}${COLOR_RESET}"
    return 0
}

xray_core_status() {
    local dir; dir=$(xray_core_dir) || {
        echo -e "${COLOR_RED}${LANG[XRAY_CORE_NO_NODE]}${COLOR_RESET}"
        return 1
    }
    echo -e ""
    printf "${COLOR_WHITE}${LANG[XRAY_CORE_STATUS_DIR]}${COLOR_RESET}\n" "$dir"
    if grep -q "$XRAY_ALT_MOUNT" "$dir/docker-compose.yml" 2>/dev/null && [ -f "$dir/$XRAY_ALT_FILE" ]; then
        echo -e "${COLOR_GREEN}${LANG[XRAY_CORE_STATUS_ALT]}${COLOR_RESET}"
        local v; v=$("$dir/$XRAY_ALT_FILE" version 2>/dev/null | head -n1)
        [ -n "$v" ] && echo -e "${COLOR_WHITE}  $v${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_STATUS_BUNDLED]}${COLOR_RESET}"
    fi
    # версия ядра, реально работающего в контейнере
    local rv; rv=$(docker exec remnanode xray version 2>/dev/null | head -n1)
    [ -n "$rv" ] && printf "${COLOR_WHITE}${LANG[XRAY_CORE_STATUS_RUNNING]}${COLOR_RESET}\n" "$rv"
    local lv; lv=$(xray_core_latest_version)
    printf "${COLOR_WHITE}${LANG[XRAY_CORE_STATUS_LATEST]}${COLOR_RESET}\n" "$lv"
    return 0
}

show_xray_core_menu() {
    [ -n "$XRAY_ALT_VERSION" ] || xray_core_resolve_version
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_12]}${COLOR_RESET}"
    echo -e ""
    printf "${COLOR_YELLOW}1. ${LANG[XRAY_CORE_MENU_INSTALL]}${COLOR_RESET}\n" "$XRAY_ALT_VERSION"
    echo -e "${COLOR_YELLOW}2. ${LANG[XRAY_CORE_MENU_RESTORE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[XRAY_CORE_MENU_STATUS]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_GRAY}${LANG[XRAY_CORE_SOURCE_NOTE]}${COLOR_RESET}"
    echo -e ""
}

manage_xray_core() {
    show_xray_core_menu
    reading "${LANG[XRAY_CORE_PROMPT]}" XRAY_CORE_OPTION
    case $XRAY_CORE_OPTION in
        1)
            if install_alt_xray_core; then
                local dir; dir=$(xray_core_dir)
                echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_RESTARTING]}${COLOR_RESET}"
                ( cd "$dir" && docker compose down > /dev/null 2>&1 )
                compose_up "$dir" && echo -e "${COLOR_GREEN}${LANG[XRAY_CORE_APPLIED]}${COLOR_RESET}"
            fi
            ;;
        2)
            if restore_bundled_xray_core; then
                local dir; dir=$(xray_core_dir)
                echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_RESTARTING]}${COLOR_RESET}"
                ( cd "$dir" && docker compose down > /dev/null 2>&1 )
                compose_up "$dir" && echo -e "${COLOR_GREEN}${LANG[XRAY_CORE_APPLIED]}${COLOR_RESET}"
            fi
            ;;
        3)
            xray_core_status
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            log_clear
            remnawave_reverse
            return
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_INVALID_CHOICE]}${COLOR_RESET}"
            ;;
    esac
    sleep 2
    log_clear
    manage_xray_core
}

# Промпт в установщике ноды: предложить альтернативное ядро сразу при установке
offer_alt_xray_core() {
    local dir="$1"
    echo -e ""
    [ -n "$XRAY_ALT_VERSION" ] || xray_core_resolve_version
    printf "${COLOR_YELLOW}${LANG[XRAY_CORE_OFFER]}${COLOR_RESET}\n" "$XRAY_ALT_VERSION"
    echo -e "${COLOR_GRAY}${LANG[XRAY_CORE_SOURCE_NOTE]}${COLOR_RESET}"
    reading "${LANG[XRAY_CORE_OFFER_PROMPT]}" ans_alt_core
    if [[ "$ans_alt_core" =~ ^[YyНн]$ ]]; then
        install_alt_xray_core "$dir" || echo -e "${COLOR_YELLOW}${LANG[XRAY_CORE_OFFER_SKIPPED]}${COLOR_RESET}"
    fi
    return 0
}
