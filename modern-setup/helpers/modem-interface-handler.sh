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
LOCK_FILE="/var/lock/modem-handler.lock"

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

# Получение номера порта для HTTP прокси на основе подсети
get_http_proxy_port() {
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

# Получение номера порта для SOCKS прокси на основе подсети
get_socks_proxy_port() {
    local subnet="$1"
    local third_octet=$(echo "$subnet" | grep -oP '\d+\.\d+\.\K\d+')

    if [ "$third_octet" -ge 2 ] && [ "$third_octet" -le 9 ]; then
        echo "900${third_octet}"
    elif [ "$third_octet" -ge 10 ] && [ "$third_octet" -le 20 ]; then
        echo "90${third_octet}"
    else
        # Для нестандартных подсетей возвращаем 0 (не настраиваем прокси)
        echo "0"
    fi
}

# Проверка коллизии портов — другой интерфейс уже занял эту подсеть
# Возвращает 0 если коллизий нет, 1 если обнаружена коллизия
check_port_collision() {
    local iface="$1"
    local subnet="$2"

    for subnet_file in "${STATE_DIR}"/*.subnet; do
        [ -f "$subnet_file" ] || continue

        # Извлекаем имя интерфейса из имени файла
        local other_iface
        other_iface=$(basename "$subnet_file" .subnet)

        # Пропускаем свой же интерфейс
        [ "$other_iface" = "$iface" ] && continue

        # Читаем подсеть другого интерфейса
        local other_subnet
        other_subnet=$(cat "$subnet_file" 2>/dev/null) || continue

        if [ "$other_subnet" = "$subnet" ]; then
            # Проверяем, существует ли блокирующий интерфейс
            if ! ip link show "$other_iface" >/dev/null 2>&1; then
                log "Обнаружен устаревший state-файл для $other_iface (интерфейс не существует), очистка..."
                rm -f "${STATE_DIR}/${other_iface}".* 2>/dev/null || true
                continue
            fi
            local http_port
            http_port=$(get_http_proxy_port "$subnet")
            local socks_port
            socks_port=$(get_socks_proxy_port "$subnet")
            log "ОШИБКА: Коллизия портов! Подсеть ${subnet}x уже используется интерфейсом $other_iface (HTTP:$http_port, SOCKS:$socks_port)"
            logger -t "$SCRIPT_NAME" -p daemon.err "Коллизия портов: $iface и $other_iface в подсети ${subnet}x (HTTP:$http_port, SOCKS:$socks_port)"
            # Сохраняем маркер коллизии
            echo "$other_iface" > "${STATE_DIR}/${iface}.collision"
            return 1
        fi
    done

    return 0
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

    # Читаем сохранённый IP если есть (атомарное чтение без TOCTOU)
    local ip=""
    ip=$(cat "${STATE_DIR}/${iface}.ip" 2>/dev/null) || true

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
    local http_port=$(get_http_proxy_port "$subnet")
    local socks_port=$(get_socks_proxy_port "$subnet")
    local expected_ip="${subnet}100"

    if [ "$http_port" = "0" ] || [ "$socks_port" = "0" ]; then
        log "Подсеть $subnet не требует настройки прокси (нестандартная подсеть)"
        return 0
    fi

    # Проверяем, совпадает ли IP со стандартным (192.168.X.100)
    if [ "$ip" = "$expected_ip" ]; then
        log "IP $ip соответствует ожидаемому, конфигурация 3proxy уже актуальна (не требует перезагрузки)"

        # Сохраняем информацию о портах
        echo "$http_port" > "${STATE_DIR}/${iface}.http_port"
        echo "$socks_port" > "${STATE_DIR}/${iface}.socks_port"

        return 0
    fi

    # IP отличается от стандартного - обновляем конфигурацию
    log "IP $ip отличается от ожидаемого $expected_ip - обновление конфигурации 3proxy..."

    # Проверяем существование конфига
    if [ ! -f "$PROXY_CFG" ]; then
        log "ОШИБКА: Конфигурация $PROXY_CFG не найдена"
        return 1
    fi

    # Создаём временный файл
    local temp_cfg=$(mktemp)
    trap "rm -f '$temp_cfg'" RETURN

    # Удаляем старые записи для этой подсети
    grep -vE "\-e${subnet}[0-9]+" "$PROXY_CFG" > "$temp_cfg"
    local grep_status=$?

    # grep возвращает 1 если нет совпадений (все строки прошли) — это OK
    # grep возвращает >1 при реальной ошибке
    if [ $grep_status -gt 1 ]; then
        log "ОШИБКА: grep завершился с ошибкой ($grep_status) при обновлении конфига"
        return 1
    fi

    # Добавляем новые записи (HTTP и SOCKS) с актуальным IP
    echo "proxy -n -a -p${http_port} -e${ip}" >> "$temp_cfg"
    echo "socks -n -a -p${socks_port} -e${ip}" >> "$temp_cfg"

    # Проверяем что результат непустой (содержит базовые директивы)
    if ! grep -q "^nserver\|^auth\|^users" "$temp_cfg"; then
        log "ОШИБКА: Результирующий конфиг повреждён (отсутствуют базовые директивы), отмена обновления"
        return 1
    fi

    # Заменяем конфигурацию
    mv "$temp_cfg" "$PROXY_CFG"
    chmod 644 "$PROXY_CFG"
    trap - RETURN

    log "3proxy конфигурация обновлена: proxy -p${http_port} -e${ip}, socks -p${socks_port} -e${ip}"

    # Сохраняем информацию о портах
    echo "$http_port" > "${STATE_DIR}/${iface}.http_port"
    echo "$socks_port" > "${STATE_DIR}/${iface}.socks_port"

    # Флаг для перезагрузки прокси
    echo "1" > "${STATE_DIR}/${iface}.needs_reload"
}

# Удаление из конфигурации 3proxy
remove_from_3proxy_config() {
    local iface="$1"

    log "Удаление из 3proxy конфигурации"

    # Читаем подсеть из сохранённого состояния (атомарное чтение без TOCTOU)
    local subnet=""
    subnet=$(cat "${STATE_DIR}/${iface}.subnet" 2>/dev/null) || true

    if [ -z "$subnet" ]; then
        log "Подсеть не найдена в сохранённом состоянии, пропускаем удаление из 3proxy"
        return 0
    fi

    # Проверяем существование конфига
    if [ ! -f "$PROXY_CFG" ]; then
        log "ОШИБКА: Конфигурация $PROXY_CFG не найдена"
        return 1
    fi

    # Создаём временный файл
    local temp_cfg=$(mktemp)
    trap "rm -f '$temp_cfg'" RETURN

    # Удаляем записи для этой подсети
    grep -vE "\-e${subnet}[0-9]+" "$PROXY_CFG" > "$temp_cfg"
    local grep_status=$?

    # grep возвращает 1 если нет совпадений (все строки прошли) — это OK
    # grep возвращает >1 при реальной ошибке
    if [ $grep_status -gt 1 ]; then
        log "ОШИБКА: grep завершился с ошибкой ($grep_status) при удалении из конфига"
        return 1
    fi

    # Проверяем что результат непустой (содержит базовые директивы)
    if ! grep -q "^nserver\|^auth\|^users" "$temp_cfg"; then
        log "ОШИБКА: Результирующий конфиг повреждён (отсутствуют базовые директивы), отмена удаления"
        return 1
    fi

    # Заменяем конфигурацию
    mv "$temp_cfg" "$PROXY_CFG"
    chmod 644 "$PROXY_CFG"
    trap - RETURN

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

    # Проверяем коллизию портов перед настройкой прокси
    if ! check_port_collision "$iface" "$subnet"; then
        log "Пропуск настройки 3proxy для $iface из-за коллизии портов (маршрутизация настроена)"
        log "========================================="
        return 2
    fi

    # Удаляем маркер коллизии если был (подсеть теперь свободна)
    rm -f "${STATE_DIR}/${iface}.collision"

    # Обновляем конфигурацию 3proxy
    update_3proxy_config "$iface" "$ip"

    # Перезапускаем 3proxy только если требуется
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

# Проверка освобождения порта для интерфейсов с коллизией
check_freed_collisions() {
    local removed_iface="$1"

    for collision_file in "${STATE_DIR}"/*.collision; do
        [ -f "$collision_file" ] || continue

        local blocking_iface
        blocking_iface=$(cat "$collision_file" 2>/dev/null) || continue

        if [ "$blocking_iface" = "$removed_iface" ]; then
            local collided_iface
            collided_iface=$(basename "$collision_file" .collision)
            log "Порт освобождён: интерфейс $collided_iface может быть переконфигурирован (был заблокирован $removed_iface)"
            logger -t "$SCRIPT_NAME" -p daemon.info "Порт освобождён: $collided_iface может быть переконфигурирован после удаления $removed_iface"
        fi
    done
}

# Обработка удаления интерфейса
handle_remove() {
    local iface="$1"

    log "========================================="
    log "Событие: REMOVE интерфейса $iface"

    # Проверяем, освобождает ли удаление порт для интерфейсов с коллизией
    check_freed_collisions "$iface"

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

    # Валидация имени интерфейса (8ve)
    if ! echo "$INTERFACE" | grep -qE '^(eth[1-9]|eth1[0-9]|eth20|usb[0-9]|usb1[0-9]|usb20)$'; then
        log "ОШИБКА: Недопустимое имя интерфейса: $INTERFACE"
        exit 1
    fi

    # Захватываем блокировку (ждём до 60 секунд)
    exec 200>"$LOCK_FILE"
    if ! flock -w 60 200; then
        log "ОШИБКА: Не удалось захватить блокировку за 60 секунд"
        exit 1
    fi
    log "Блокировка захвачена"

    local exit_code=0
    case "$ACTION" in
        "add")
            handle_add "$INTERFACE" || exit_code=$?
            ;;
        "remove")
            handle_remove "$INTERFACE" || exit_code=$?
            ;;
        *)
            log "ОШИБКА: Неизвестное действие: $ACTION"
            exit_code=1
            ;;
    esac

    # Блокировка автоматически освобождается при закрытии fd
    exec 200>&-

    # Логируем в syslog при ошибке (p2a), код 2 = коллизия портов (не ошибка)
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 2 ]; then
        log "ОШИБКА: Обработка $ACTION для $INTERFACE завершилась с кодом $exit_code"
        logger -t "$SCRIPT_NAME" -p daemon.err "ОШИБКА: $ACTION $INTERFACE завершился с кодом $exit_code"
    fi

    return $exit_code
}

main "$@"
