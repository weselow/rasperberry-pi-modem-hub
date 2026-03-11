#!/bin/bash
#
# 03-configure-network.sh - Настраивает сетевые интерфейсы и таблицы маршрутизации (Alpine Linux)
# Может запускаться повторно - проверяет существование перед добавлением
#

set -e

SCRIPT_NAME="03-configure-network"
RT_TABLES="/etc/iproute2/rt_tables"
NETWORK_INTERFACES="/etc/network/interfaces"
MAX_MODEMS=20

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[${SCRIPT_NAME}]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[${SCRIPT_NAME}]${NC} $1"
}

log_error() {
    echo -e "${RED}[${SCRIPT_NAME}]${NC} $1"
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

# Добавление таблицы маршрутизации в rt_tables
add_routing_table() {
    local table_id="$1"
    local table_name="$2"

    if grep -qE "^${table_id}[[:space:]]+${table_name}" "$RT_TABLES" 2>/dev/null; then
        log_warn "Таблица маршрутизации уже существует: $table_id $table_name"
        return 1
    fi

    echo "$table_id      $table_name" >> "$RT_TABLES"
    log_info "Добавлена таблица маршрутизации: $table_id $table_name"
    return 0
}

# Настройка таблиц маршрутизации
configure_routing_tables() {
    log_info "Настройка таблиц маршрутизации в $RT_TABLES..."

    local changes=0

    # Создаём таблицы для eth интерфейсов (eth1-eth20)
    for ((i=1; i <= MAX_MODEMS; i++)); do
        local table_id=$((i + 11))
        local table_name="modemeth${i}"
        add_routing_table "$table_id" "$table_name" && ((changes++))
    done

    # Создаём таблицы для usb интерфейсов (usb0-usb20)
    for ((i=0; i <= MAX_MODEMS; i++)); do
        local table_id=$((i + 32))
        local table_name="modemusb${i}"
        add_routing_table "$table_id" "$table_name" && ((changes++))
    done

    if [ $changes -gt 0 ]; then
        log_info "Добавлено таблиц маршрутизации: $changes"
    else
        log_info "Таблицы маршрутизации уже настроены"
    fi
}

# Настройка /etc/network/interfaces для Alpine
configure_alpine_network() {
    log_info "Настройка /etc/network/interfaces (Alpine Linux)..."

    if [ ! -f "$NETWORK_INTERFACES" ]; then
        log_warn "Файл $NETWORK_INTERFACES не найден"
        touch "$NETWORK_INTERFACES"
    fi

    # Проверяем, настроены ли уже интерфейсы модемов
    if grep -q "# Modem interfaces auto-configured" "$NETWORK_INTERFACES" 2>/dev/null; then
        log_warn "Интерфейсы модемов уже настроены в $NETWORK_INTERFACES"
        return 0
    fi

    log_info "Добавление настроек для интерфейсов модемов (eth1-eth20, usb0-usb20)..."

    # FUNC-6: Генерируем все 20 интерфейсов через цикл вместо ручного перечисления.
    # Ранее добавлялись только первые 5, остальные 15 не работали.

    echo "" >> "$NETWORK_INTERFACES"
    echo "# Modem interfaces auto-configured by modern-setup-alpine" >> "$NETWORK_INTERFACES"
    echo "# These interfaces use DHCP but don't set default gateway" >> "$NETWORK_INTERFACES"

    # eth1-eth20
    echo "" >> "$NETWORK_INTERFACES"
    echo "# eth1-eth20 interfaces" >> "$NETWORK_INTERFACES"
    for i in $(seq 1 "$MAX_MODEMS"); do
        cat >> "$NETWORK_INTERFACES" << EOF

auto eth${i}
iface eth${i} inet dhcp
    post-up ip route del default dev eth${i} 2>/dev/null || true
EOF
    done

    # usb0-usb20
    echo "" >> "$NETWORK_INTERFACES"
    echo "# usb0-usb20 interfaces" >> "$NETWORK_INTERFACES"
    for i in $(seq 0 "$MAX_MODEMS"); do
        cat >> "$NETWORK_INTERFACES" << EOF

auto usb${i}
iface usb${i} inet dhcp
    post-up ip route del default dev usb${i} 2>/dev/null || true
EOF
    done

    log_info "Настройки интерфейсов добавлены в $NETWORK_INTERFACES (eth1-eth${MAX_MODEMS}, usb0-usb${MAX_MODEMS})"
}

# Настройка udhcpc (Alpine DHCP client)
configure_udhcpc() {
    log_info "Настройка udhcpc для Alpine..."

    local udhcpc_script="/etc/udhcpc/udhcpc.conf"
    local udhcpc_dir="/etc/udhcpc"

    # В Alpine udhcpc настраивается через /etc/network/interfaces
    # Специальной конфигурации не требуется, т.к. мы используем post-up хуки

    log_info "udhcpc будет использовать настройки из /etc/network/interfaces"
}

# Главная функция
main() {
    log_info "Начало настройки сети (Alpine Linux)..."

    check_root

    # Настраиваем таблицы маршрутизации (общее для всех)
    configure_routing_tables

    # Настраиваем сетевые интерфейсы для Alpine
    configure_alpine_network

    # Настраиваем udhcpc
    configure_udhcpc

    log_info "Настройка сети завершена!"
    log_info ""
    log_info "Следующие шаги:"
    log_info "  1. Запустите скрипт 04-setup-udev-rules.sh для настройки автоматического управления модемами"
    log_info "  2. Перезагрузите систему или перезапустите сетевые сервисы:"
    log_info "     rc-service networking restart"
}

main "$@"
