#!/bin/bash
#
# 03-configure-network.sh - Настраивает сетевые интерфейсы и таблицы маршрутизации
# Может запускаться повторно - проверяет существование перед добавлением
#

set -e

SCRIPT_NAME="03-configure-network"
RT_TABLES="/etc/iproute2/rt_tables"
NETWORKD_DIR="/etc/systemd/network"
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
    # table_id начинается с 12 для eth1, 13 для eth2, и т.д.
    for ((i=1; i <= MAX_MODEMS; i++)); do
        local table_id=$((i + 11))
        local table_name="modemeth${i}"
        add_routing_table "$table_id" "$table_name" && changes=$((changes+1))
    done

    # Создаём таблицы для usb интерфейсов (usb0-usb20)
    # table_id начинается с 32 для usb0 (12 + 20)
    for ((i=0; i <= MAX_MODEMS; i++)); do
        local table_id=$((i + 32))
        local table_name="modemusb${i}"
        add_routing_table "$table_id" "$table_name" && changes=$((changes+1))
    done

    if [ $changes -gt 0 ]; then
        log_info "Добавлено таблиц маршрутизации: $changes"
    else
        log_info "Таблицы маршрутизации уже настроены"
    fi
}

# Определение используемого network backend
detect_network_backend() {
    if systemctl is-active --quiet NetworkManager; then
        echo "NetworkManager"
    elif systemctl is-enabled --quiet systemd-networkd 2>/dev/null; then
        echo "systemd-networkd"
    elif [ -f "/etc/dhcpcd.conf" ]; then
        echo "dhcpcd"
    else
        echo "unknown"
    fi
}

# Настройка для systemd-networkd
configure_systemd_networkd() {
    log_info "Настройка systemd-networkd..."

    mkdir -p "$NETWORKD_DIR"

    # Создаём конфигурацию для eth интерфейсов
    for ((i=1; i <= MAX_MODEMS; i++)); do
        local config_file="${NETWORKD_DIR}/10-modem-eth${i}.network"

        if [ -f "$config_file" ]; then
            log_warn "Конфигурация уже существует: $config_file"
            continue
        fi

        cat > "$config_file" << EOF
[Match]
Name=eth${i}

[Network]
DHCP=yes
# Не использовать этот интерфейс как gateway по умолчанию
DefaultRoute=false

[DHCP]
UseRoutes=false
UseDNS=false
EOF

        log_info "Создана конфигурация: $config_file"
    done

    # Создаём конфигурацию для usb интерфейсов
    for ((i=0; i <= MAX_MODEMS; i++)); do
        local config_file="${NETWORKD_DIR}/10-modem-usb${i}.network"

        if [ -f "$config_file" ]; then
            log_warn "Конфигурация уже существует: $config_file"
            continue
        fi

        cat > "$config_file" << EOF
[Match]
Name=usb${i}

[Network]
DHCP=yes
# Не использовать этот интерфейс как gateway по умолчанию
DefaultRoute=false

[DHCP]
UseRoutes=false
UseDNS=false
EOF

        log_info "Создана конфигурация: $config_file"
    done

    # Включаем systemd-networkd если он ещё не включен
    if ! systemctl is-enabled --quiet systemd-networkd; then
        log_info "Включение systemd-networkd..."
        systemctl enable systemd-networkd
    fi

    log_info "systemd-networkd настроен"
}

# Настройка для NetworkManager
configure_networkmanager() {
    log_info "Настройка NetworkManager..."

    local nm_conf_dir="/etc/NetworkManager/conf.d"
    local nm_modem_conf="${nm_conf_dir}/99-modem-interfaces.conf"

    mkdir -p "$nm_conf_dir"

    if [ -f "$nm_modem_conf" ]; then
        log_warn "Конфигурация NetworkManager уже существует: $nm_modem_conf"
    else
        cat > "$nm_modem_conf" << 'EOF'
# Настройка для интерфейсов модемов
# Отключаем автоматический default route для модемов

[connection]
# Применяем к интерфейсам ethX и usbX
match-device=interface-name:eth*,usb*

[ipv4]
never-default=true
ignore-auto-dns=true

[ipv6]
method=disabled
EOF

        log_info "Создана конфигурация: $nm_modem_conf"
        log_warn "Требуется перезапустить NetworkManager: systemctl restart NetworkManager"
    fi
}

# Настройка для dhcpcd (старый метод, для совместимости)
configure_dhcpcd() {
    log_warn "Обнаружен dhcpcd - устаревший метод!"
    log_warn "Рекомендуется использовать systemd-networkd или NetworkManager"

    local dhcpcd_conf="/etc/dhcpcd.conf"

    if [ ! -f "$dhcpcd_conf" ]; then
        log_error "Файл $dhcpcd_conf не найден"
        return 1
    fi

    log_info "Добавление интерфейсов в $dhcpcd_conf..."

    local changes=0

    # eth интерфейсы
    for ((i=1; i <= MAX_MODEMS; i++)); do
        if ! grep -q "^interface eth${i}" "$dhcpcd_conf"; then
            echo "" >> "$dhcpcd_conf"
            echo "interface eth${i}" >> "$dhcpcd_conf"
            echo "nogateway" >> "$dhcpcd_conf"
            log_info "Добавлен интерфейс: eth${i}"
            ((changes++))
        fi
    done

    # usb интерфейсы
    for ((i=0; i <= MAX_MODEMS; i++)); do
        if ! grep -q "^interface usb${i}" "$dhcpcd_conf"; then
            echo "" >> "$dhcpcd_conf"
            echo "interface usb${i}" >> "$dhcpcd_conf"
            echo "nogateway" >> "$dhcpcd_conf"
            log_info "Добавлен интерфейс: usb${i}"
            ((changes++))
        fi
    done

    if [ $changes -gt 0 ]; then
        log_info "Добавлено интерфейсов в dhcpcd: $changes"
        log_warn "Требуется перезапустить dhcpcd: systemctl restart dhcpcd"
    else
        log_info "Интерфейсы уже настроены в dhcpcd"
    fi
}

# Главная функция
main() {
    log_info "Начало настройки сети..."

    check_root

    # Настраиваем таблицы маршрутизации (общее для всех)
    configure_routing_tables

    # Определяем используемый network backend
    local backend=$(detect_network_backend)
    log_info "Обнаружен network backend: $backend"

    case "$backend" in
        "systemd-networkd")
            configure_systemd_networkd
            ;;
        "NetworkManager")
            configure_networkmanager
            ;;
        "dhcpcd")
            configure_dhcpcd
            ;;
        "unknown")
            log_warn "Не удалось определить network backend"
            log_info "Создаём конфигурацию для systemd-networkd..."
            configure_systemd_networkd
            ;;
    esac

    log_info "Настройка сети завершена!"
    log_info ""
    log_info "Следующие шаги:"
    log_info "  1. Запустите скрипт 04-setup-udev-rules.sh для настройки автоматического управления модемами"
    log_info "  2. Перезагрузите систему или перезапустите сетевые сервисы"
}

main "$@"
