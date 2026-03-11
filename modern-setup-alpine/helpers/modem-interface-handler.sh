#!/bin/bash
#
# modem-interface-handler.sh - Обрабатывает события появления/удаления интерфейсов модемов (Alpine Linux)
# Вызывается из udev rules при подключении/отключении модема
#
# Аргументы:
#   $1 - ACTION (add/remove)
#   $2 - INTERFACE (eth1, usb0, etc.)
#

# FUNC-2: Убран set -e — скрипт вызывается из udev, который не логирует stderr
# и убивает процесс при падении без каких-либо сообщений об ошибке.
# Используем явную обработку ошибок с логированием.

SCRIPT_NAME="modem-handler"
ACTION="$1"
INTERFACE="$2"
LOGFILE="/var/log/modem-handler.log"
PROXY_CFG="/etc/3proxy/3proxy.cfg"
STATE_DIR="/var/run/modem-state"

# BUG-1: Файл блокировки для предотвращения race condition при одновременном
# подключении нескольких модемов и конкурентной записи в 3proxy.cfg
LOCK_FILE="/var/lock/3proxy-cfg.lock"

# Создаём директорию для хранения состояний
mkdir -p "$STATE_DIR"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$SCRIPT_NAME] [$INTERFACE] $1" >> "$LOGFILE"
}

# Получение IP-адреса интерфейса
get_interface_ip() {
    local iface="$1"
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local ip
        ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -n1)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        sleep 1
        ((attempt++))
    done

    return 1
}

# Получение подсети из IP
get_subnet() {
    local ip="$1"
    echo "$ip" | grep -oP '\d+\.\d+\.\d+\.'
}

# Получение gateway для подсети
get_gateway() {
    local subnet="$1"
    echo "${subnet}1"
}

# Получение номера порта для HTTP прокси на основе подсети
get_http_proxy_port() {
    local subnet="$1"
    local third_octet
    third_octet=$(echo "$subnet" | grep -oP '\d+\.\d+\.\K\d+')

    if [ "$third_octet" -ge 2 ] && [ "$third_octet" -le 9 ]; then
        echo "800${third_octet}"
    elif [ "$third_octet" -ge 10 ] && [ "$third_octet" -le 20 ]; then
        echo "80${third_octet}"
    else
        echo "0"
    fi
}

# Получение номера порта для SOCKS прокси на основе подсети
get_socks_proxy_port() {
    local subnet="$1"
    local third_octet
    third_octet=$(echo "$subnet" | grep -oP '\d+\.\d+\.\K\d+')

    if [ "$third_octet" -ge 2 ] && [ "$third_octet" -le 9 ]; then
        echo "900${third_octet}"
    elif [ "$third_octet" -ge 10 ] && [ "$third_octet" -le 20 ]; then
        echo "90${third_octet}"
    else
        echo "0"
    fi
}

# Получение имени таблицы маршрутизации
get_routing_table() {
    local iface="$1"
    echo "modem${iface}"
}

# Настройка маршрутизации для интерфейса
setup_routing() {
    local iface="$1"
    local ip="$2"
    local subnet
    subnet=$(get_subnet "$ip")
    local gateway
    gateway=$(get_gateway "$subnet")
    local table
    table=$(get_routing_table "$iface")

    log "Настройка маршрутизации: IP=$ip, subnet=$subnet, gateway=$gateway, table=$table"

    ip rule del from "$ip" 2>/dev/null || true
    ip route flush table "$table" 2>/dev/null || true

    if ! ip route add default via "$gateway" dev "$iface" table "$table"; then
        log "ОШИБКА: Не удалось добавить маршрут default via $gateway dev $iface table $table"
        return 1
    fi
    log "Добавлен маршрут: default via $gateway dev $iface table $table"

    if ! ip rule add from "$ip" table "$table"; then
        log "ОШИБКА: Не удалось добавить правило from $ip table $table"
        ip route flush table "$table" 2>/dev/null || true
        return 1
    fi
    log "Добавлено правило: from $ip table $table"

    echo "$ip" > "${STATE_DIR}/${iface}.ip"
    echo "$subnet" > "${STATE_DIR}/${iface}.subnet"
    echo "$gateway" > "${STATE_DIR}/${iface}.gateway"

    return 0
}

# Удаление маршрутизации для интерфейса
remove_routing() {
    local iface="$1"
    local table
    table=$(get_routing_table "$iface")

    log "Удаление маршрутизации для интерфейса $iface"

    local ip=""
    if [ -f "${STATE_DIR}/${iface}.ip" ]; then
        ip=$(cat "${STATE_DIR}/${iface}.ip")
    fi

    if [ -n "$ip" ]; then
        ip rule del from "$ip" 2>/dev/null || true
        log "Удалено правило: from $ip"
    fi

    ip route flush table "$table" 2>/dev/null || true
    log "Очищена таблица: $table"

    rm -f "${STATE_DIR}/${iface}".* 2>/dev/null || true
}

# Обновление конфигурации 3proxy
# BUG-1: flock защищает от race condition при одновременном подключении модемов
update_3proxy_config() {
    local iface="$1"
    local ip="$2"
    local subnet
    subnet=$(get_subnet "$ip")
    local http_port
    http_port=$(get_http_proxy_port "$subnet")
    local socks_port
    socks_port=$(get_socks_proxy_port "$subnet")
    local expected_ip="${subnet}100"

    if [ "$http_port" = "0" ] || [ "$socks_port" = "0" ]; then
        log "Подсеть $subnet не требует настройки прокси (нестандартная подсеть)"
        return 0
    fi

    if [ "$ip" = "$expected_ip" ]; then
        log "IP $ip соответствует ожидаемому, конфигурация 3proxy уже актуальна (не требует перезагрузки)"
        echo "$http_port" > "${STATE_DIR}/${iface}.http_port"
        echo "$socks_port" > "${STATE_DIR}/${iface}.socks_port"
        return 0
    fi

    log "IP $ip отличается от ожидаемого $expected_ip - обновление конфигурации 3proxy..."

    (
        flock -x -w 30 200 || {
            log "ОШИБКА: Таймаут ожидания блокировки конфига 3proxy (30с)"
            exit 1
        }

        local temp_cfg
        temp_cfg=$(mktemp)

        grep -vE "\-e${subnet}[0-9]+" "$PROXY_CFG" > "$temp_cfg" || true
        echo "proxy -n -a -p${http_port} -e${ip}" >> "$temp_cfg"
        echo "socks -n -a -p${socks_port} -e${ip}" >> "$temp_cfg"

        mv "$temp_cfg" "$PROXY_CFG"
        chmod 644 "$PROXY_CFG"
    ) 200>"$LOCK_FILE" || return 1

    log "3proxy конфигурация обновлена: proxy -p${http_port} -e${ip}, socks -p${socks_port} -e${ip}"

    echo "$http_port" > "${STATE_DIR}/${iface}.http_port"
    echo "$socks_port" > "${STATE_DIR}/${iface}.socks_port"
    echo "1" > "${STATE_DIR}/${iface}.needs_reload"
}

# Удаление из конфигурации 3proxy
# BUG-1: flock для защиты от race condition
# FUNC-1: возвращает 0 если конфиг изменился, 1 если нет
remove_from_3proxy_config() {
    local iface="$1"

    log "Удаление из 3proxy конфигурации"

    local subnet=""
    if [ -f "${STATE_DIR}/${iface}.subnet" ]; then
        subnet=$(cat "${STATE_DIR}/${iface}.subnet")
    fi

    if [ -z "$subnet" ]; then
        log "Подсеть не найдена в сохранённом состоянии, пропускаем удаление из 3proxy"
        return 1
    fi

    (
        flock -x -w 30 200 || {
            log "ОШИБКА: Таймаут ожидания блокировки конфига 3proxy (30с)"
            exit 1
        }

        local temp_cfg
        temp_cfg=$(mktemp)

        grep -vE "\-e${subnet}[0-9]+" "$PROXY_CFG" > "$temp_cfg" || true

        if cmp -s "$PROXY_CFG" "$temp_cfg"; then
            rm -f "$temp_cfg"
            exit 2  # нет изменений
        fi

        mv "$temp_cfg" "$PROXY_CFG"
        chmod 644 "$PROXY_CFG"
    ) 200>"$LOCK_FILE"

    local exit_code=$?

    if [ $exit_code -eq 2 ]; then
        log "Записей для подсети ${subnet}x в конфиге не найдено, перезапуск не нужен"
        return 1
    elif [ $exit_code -ne 0 ]; then
        log "ОШИБКА: Не удалось обновить конфигурацию 3proxy"
        return 1
    fi

    log "Удалено из 3proxy конфигурации: подсеть ${subnet}x"
    return 0
}

# Перезапуск 3proxy (OpenRC)
restart_3proxy() {
    log "Перезапуск 3proxy..."

    if rc-service 3proxy status >/dev/null 2>&1; then
        rc-service 3proxy restart
        log "3proxy перезапущен"
    else
        log "3proxy не запущен, запускаем..."
        rc-service 3proxy start
        log "3proxy запущен"
    fi
}

# Обработка добавления интерфейса
handle_add() {
    local iface="$1"

    log "========================================="
    log "Событие: ADD интерфейса $iface"

    log "Ожидание получения IP-адреса..."
    local ip
    ip=$(get_interface_ip "$iface")

    if [ -z "$ip" ]; then
        log "ОШИБКА: Не удалось получить IP-адрес для $iface за 30 секунд"
        return 1
    fi

    log "Получен IP-адрес: $ip"

    # BUG-2: Проверяем полный адрес — модемы E3372 всегда используют 192.168.x.x.
    # Проверка только третьего октета недостаточна: локальная сеть 192.168.2.x
    # или 10.20.2.x прошла бы фильтр с третьим октетом = 2.
    local first_octet second_octet third_octet
    first_octet=$(echo "$ip" | cut -d'.' -f1)
    second_octet=$(echo "$ip" | cut -d'.' -f2)
    third_octet=$(echo "$ip" | cut -d'.' -f3)

    if [ "$first_octet" != "192" ] || [ "$second_octet" != "168" ]; then
        log "IP $ip не является адресом модема (ожидается 192.168.x.x), пропускаем"
        return 0
    fi

    if [ "$third_octet" = "0" ] || [ "$third_octet" = "1" ]; then
        log "Подсеть 192.168.${third_octet}.x зарезервирована для локальной сети, пропускаем"
        return 0
    fi

    if ! setup_routing "$iface" "$ip"; then
        log "ОШИБКА: Не удалось настроить маршрутизацию для $iface"
        return 1
    fi

    update_3proxy_config "$iface" "$ip"

    if [ -f "${STATE_DIR}/${iface}.needs_reload" ]; then
        restart_3proxy
        rm -f "${STATE_DIR}/${iface}.needs_reload"
        log "3proxy перезагружен из-за нестандартного IP"
    else
        log "3proxy не требует перезагрузки"
    fi

    log "Интерфейс $iface успешно настроен"
    log "========================================="
}

# Обработка удаления интерфейса
handle_remove() {
    local iface="$1"

    log "========================================="
    log "Событие: REMOVE интерфейса $iface"

    remove_routing "$iface"

    # FUNC-1: Перезапускаем 3proxy только если конфиг реально изменился
    if remove_from_3proxy_config "$iface"; then
        restart_3proxy
    else
        log "Конфигурация 3proxy не изменилась, перезапуск пропущен"
    fi

    log "Интерфейс $iface успешно удалён из конфигурации"
    log "========================================="
}

# Главная функция
main() {
    if [ -z "$ACTION" ] || [ -z "$INTERFACE" ]; then
        echo "Usage: $0 <add|remove> <interface>"
        exit 1
    fi

    case "$ACTION" in
        "add")
            handle_add "$INTERFACE"
            ;;
        "remove")
            handle_remove "$INTERFACE"
            ;;
        *)
            log "ОШИБКА: Неизвестное действие: $ACTION"
            exit 1
            ;;
    esac
}

main "$@"
