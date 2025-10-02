#!/bin/bash
#
# 05-install-sync-service.sh - Устанавливает systemd service для синхронизации модемов при загрузке
# Может запускаться повторно
#

set -e

SCRIPT_NAME="05-install-sync"
SYSTEMD_SERVICE="/etc/systemd/system/modem-sync.service"
SYNC_SCRIPT="/usr/local/bin/modem-sync.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_TEMPLATE="${SCRIPT_DIR}/../templates/modem-sync.service"
SYNC_SOURCE="${SCRIPT_DIR}/../helpers/modem-sync.sh"

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

# Установка sync скрипта
install_sync_script() {
    if [ ! -f "$SYNC_SOURCE" ]; then
        log_error "Sync скрипт не найден: $SYNC_SOURCE"
        exit 1
    fi

    log_info "Установка sync скрипта..."

    if [ -f "$SYNC_SCRIPT" ]; then
        local backup="${SYNC_SCRIPT}.backup.$(date +%s)"
        cp "$SYNC_SCRIPT" "$backup"
        log_warn "Создан бэкап: $backup"
    fi

    cp "$SYNC_SOURCE" "$SYNC_SCRIPT"
    chmod +x "$SYNC_SCRIPT"

    log_info "Sync скрипт установлен: $SYNC_SCRIPT"
}

# Установка systemd service
install_systemd_service() {
    if [ ! -f "$SERVICE_TEMPLATE" ]; then
        log_error "Service template не найден: $SERVICE_TEMPLATE"
        exit 1
    fi

    log_info "Установка systemd service..."

    if [ -f "$SYSTEMD_SERVICE" ]; then
        local backup="${SYSTEMD_SERVICE}.backup.$(date +%s)"
        cp "$SYSTEMD_SERVICE" "$backup"
        log_warn "Создан бэкап: $backup"
    fi

    cp "$SERVICE_TEMPLATE" "$SYSTEMD_SERVICE"
    chmod 644 "$SYSTEMD_SERVICE"

    systemctl daemon-reload

    log_info "Systemd service установлен: $SYSTEMD_SERVICE"
}

# Включение сервиса
enable_service() {
    log_info "Включение modem-sync.service..."

    systemctl enable modem-sync.service

    log_info "Сервис modem-sync.service включен (запуск при загрузке)"
}

# Тестовый запуск
test_service() {
    log_info "Тестовый запуск сервиса..."

    if systemctl start modem-sync.service; then
        log_info "Сервис успешно запущен"
        sleep 2

        # Показываем статус
        systemctl status modem-sync.service --no-pager || true

        log_info ""
        log_info "Последние записи из лога:"
        tail -n 20 /var/log/modem-handler.log 2>/dev/null || log_warn "Лог пуст"
    else
        log_error "Не удалось запустить сервис"
        systemctl status modem-sync.service --no-pager
        exit 1
    fi
}

# Главная функция
main() {
    log_info "Установка modem-sync service..."

    check_root
    install_sync_script
    install_systemd_service
    enable_service

    log_info ""
    log_info "Modem-sync service установлен!"
    log_info ""
    read -p "Запустить тестовую синхронизацию сейчас? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        test_service
    fi

    log_info ""
    log_info "Команды для управления:"
    log_info "  systemctl status modem-sync   - статус"
    log_info "  systemctl start modem-sync    - запустить синхронизацию"
    log_info "  journalctl -u modem-sync -f   - логи systemd"
    log_info "  tail -f /var/log/modem-handler.log - логи обработчика"
}

main "$@"
