#!/bin/bash
#
# modem-interface-handler.sh - Обрабатывает события появления/удаления интерфейсов модемов
# Вызывается из udev rules при подключении/отключении модема
#
# Аргументы:
#   $1 - ACTION (add/remove)
#   $2 - INTERFACE (eth1, usb0, etc.)
#

set -e

SCRIPT_NAME="modem-handler"
ACTION="$1"
INTERFACE="$2"
LOGFILE="/var/log/modem-handler.log"
PROXY_CFG="/etc/3proxy/3proxy.cfg"
STATE_DIR="/var/run/modem-state"

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
        local ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -n1)
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

# Получение номера порта для 3proxy на основе подсети
get_proxy_port() {
    local subnet="$1"
    local third_octet=$(echo "$subnet" | grep -oP '\d+\.\d+\.\K\d+')

    if [ "$third_octet" -ge 2 ] && [ "$third_octet" -le 9 ]; then
        echo "800${third_octet}"
    elif [ "$third_octet" -ge 10 ] && [ "$third_octet" -le 20 ]; then
        echo "80${third_octet}"
    else
        # Для нестандартных подсетей возвращаем 0 (не настраиваем прокси)
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
    local subnet=$(get_subnet "$ip")
    local gateway=$(get_gateway "$subnet")
    local table=$(get_routing_table "$iface")

    log "Настройка маршрутизации: IP=$ip, subnet=$subnet, gateway=$gateway, table=$table"

    # Удаляем существующие правила для этого IP (на случай реконфигурации)
    ip rule del from "$ip" 2>/dev/null || true

    # Удаляем существующие маршруты в таблице
    ip route flush table "$table" 2>/dev/null || true

    # Добавляем default route в таблицу
    ip route add default via "$gateway" dev "$iface" table "$table"
    log "Добавлен маршрут: default via $gateway dev $iface table $table"

    # Добавляем правило маршрутизации
    ip rule add from "$ip" table "$table"
    log "Добавлено правило: from $ip table $table"

    # Сохраняем состояние интерфейса
    echo "$ip" > "${STATE_DIR}/${iface}.ip"
    echo "$subnet" > "${STATE_DIR}/${iface}.subnet"
    echo "$gateway" > "${STATE_DIR}/${iface}.gateway"
}

# Удаление маршрутизации для интерфейса
remove_routing() {
    local iface="$1"
    local table=$(get_routing_table "$iface")

    log "Удаление маршрутизации для интерфейса $iface"

    # Читаем сохранённый IP если есть
    local ip=""
    if [ -f "${STATE_DIR}/${iface}.ip" ]; then
        ip=$(cat "${STATE_DIR}/${iface}.ip")
    fi

    # Удаляем правила маршрутизации
    if [ -n "$ip" ]; then
        ip rule del from "$ip" 2>/dev/null || true
        log "Удалено правило: from $ip"
    fi

    # Очищаем таблицу маршрутизации
    ip route flush table "$table" 2>/dev/null || true
    log "Очищена таблица: $table"

    # Удаляем файлы состояния
    rm -f "${STATE_DIR}/${iface}".* 2>/dev/null || true
}

# Обновление конфигурации 3proxy
update_3proxy_config() {
    local iface="$1"
    local ip="$2"
    local subnet=$(get_subnet "$ip")
    local port=$(get_proxy_port "$subnet")

    if [ "$port" = "0" ]; then
        log "Подсеть $subnet не требует настройки прокси (нестандартная подсеть)"
        return 0
    fi

    log "Обновление 3proxy конфигурации: port=$port, ip=$ip"

    # Создаём временный файл
    local temp_cfg=$(mktemp)

    # Удаляем старые записи для этой подсети
    grep -vE "\-e${subnet}[0-9]+" "$PROXY_CFG" > "$temp_cfg" || true

    # Добавляем новую запись
    echo "proxy -n -a -p${port} -e${ip}" >> "$temp_cfg"

    # Заменяем конфигурацию
    mv "$temp_cfg" "$PROXY_CFG"
    chmod 644 "$PROXY_CFG"

    log "3proxy конфигурация обновлена: proxy -n -a -p${port} -e${ip}"

    # Сохраняем информацию о порте
    echo "$port" > "${STATE_DIR}/${iface}.port"
}

# Удаление из конфигурации 3proxy
remove_from_3proxy_config() {
    local iface="$1"

    log "Удаление из 3proxy конфигурации"

    # Читаем подсеть из сохранённого состояния
    local subnet=""
    if [ -f "${STATE_DIR}/${iface}.subnet" ]; then
        subnet=$(cat "${STATE_DIR}/${iface}.subnet")
    fi

    if [ -z "$subnet" ]; then
        log "Подсеть не найдена в сохранённом состоянии, пропускаем удаление из 3proxy"
        return 0
    fi

    # Создаём временный файл
    local temp_cfg=$(mktemp)

    # Удаляем записи для этой подсети
    grep -vE "\-e${subnet}[0-9]+" "$PROXY_CFG" > "$temp_cfg" || true

    # Заменяем конфигурацию
    mv "$temp_cfg" "$PROXY_CFG"
    chmod 644 "$PROXY_CFG"

    log "Удалено из 3proxy конфигурации: подсеть ${subnet}x"
}

# Перезапуск 3proxy
restart_3proxy() {
    log "Перезапуск 3proxy..."

    if systemctl is-active --quiet 3proxy.service; then
        systemctl restart 3proxy.service
        log "3proxy перезапущен"
    else
        log "3proxy не запущен, запускаем..."
        systemctl start 3proxy.service
        log "3proxy запущен"
    fi
}

# Обработка добавления интерфейса
handle_add() {
    local iface="$1"

    log "========================================="
    log "Событие: ADD интерфейса $iface"

    # Ждём получения IP-адреса
    log "Ожидание получения IP-адреса..."
    local ip=$(get_interface_ip "$iface")

    if [ -z "$ip" ]; then
        log "ОШИБКА: Не удалось получить IP-адрес для $iface"
        return 1
    fi

    log "Получен IP-адрес: $ip"

    # Проверяем, что это модемная подсеть (192.168.X.X, исключая 0 и 1)
    local subnet=$(get_subnet "$ip")
    local third_octet=$(echo "$subnet" | grep -oP '\d+\.\d+\.\K\d+')

    if [ "$third_octet" = "0" ] || [ "$third_octet" = "1" ]; then
        log "Подсеть ${subnet}x - системная, пропускаем настройку"
        return 0
    fi

    # Настраиваем маршрутизацию
    setup_routing "$iface" "$ip"

    # Обновляем конфигурацию 3proxy
    update_3proxy_config "$iface" "$ip"

    # Перезапускаем 3proxy
    restart_3proxy

    log "Интерфейс $iface успешно настроен"
    log "========================================="
}

# Обработка удаления интерфейса
handle_remove() {
    local iface="$1"

    log "========================================="
    log "Событие: REMOVE интерфейса $iface"

    # Удаляем маршрутизацию
    remove_routing "$iface"

    # Удаляем из конфигурации 3proxy
    remove_from_3proxy_config "$iface"

    # Перезапускаем 3proxy
    restart_3proxy

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
