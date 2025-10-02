#!/bin/bash
#
# install.sh - Главный скрипт установки современной системы управления модемами
# Запускает все скрипты установки по порядку
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_header() {
    echo ""
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}$1${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo ""
}

log_info() {
    echo -e "${GREEN}[INSTALL]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[INSTALL]${NC} $1"
}

log_error() {
    echo -e "${RED}[INSTALL]${NC} $1"
}

log_step() {
    echo -e "${BOLD}[ШАГ $1]${NC} $2"
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

show_welcome() {
    clear
    log_header "УСТАНОВКА СИСТЕМЫ УПРАВЛЕНИЯ МОДЕМАМИ"

    echo "Эта установка настроит систему для автоматического управления"
    echo "несколькими USB-модемами через 3proxy с использованием udev + systemd."
    echo ""
    echo "Будут выполнены следующие шаги:"
    echo "  1. Настройка системных лимитов"
    echo "  2. Установка и настройка 3proxy"
    echo "  3. Настройка сетевых интерфейсов и маршрутизации"
    echo "  4. Установка udev правил для автоматической настройки модемов"
    echo "  5. Установка systemd service для синхронизации при загрузке"
    echo ""
    echo "Все скрипты идемпотентны - можно запускать повторно."
    echo ""
}

confirm_installation() {
    read -p "Продолжить установку? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log_warn "Установка отменена пользователем"
        exit 0
    fi
}

run_script() {
    local step_num="$1"
    local script_name="$2"
    local script_path="${SCRIPTS_DIR}/${script_name}"

    if [ ! -f "$script_path" ]; then
        log_error "Скрипт не найден: $script_path"
        exit 1
    fi

    if [ ! -x "$script_path" ]; then
        chmod +x "$script_path"
    fi

    log_header "ШАГ ${step_num}: ${script_name}"

    if bash "$script_path"; then
        log_info "✓ Шаг ${step_num} выполнен успешно"
        return 0
    else
        log_error "✗ Ошибка на шаге ${step_num}"
        log_error "Скрипт: $script_path"

        read -p "Продолжить установку несмотря на ошибку? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_warn "Продолжаем установку..."
            return 0
        else
            log_error "Установка прервана"
            exit 1
        fi
    fi
}

show_completion() {
    log_header "УСТАНОВКА ЗАВЕРШЕНА!"

    echo "Все компоненты успешно установлены и настроены."
    echo ""
    echo "Что дальше:"
    echo ""
    echo "  1. Подключите модемы к USB-портам"
    echo "  2. Модемы будут автоматически настроены через udev"
    echo "  3. Проверьте логи: tail -f /var/log/modem-handler.log"
    echo "  4. Проверьте 3proxy: systemctl status 3proxy"
    echo ""
    echo "Полезные команды:"
    echo ""
    echo "  # Проверка активных интерфейсов"
    echo "  ip addr show | grep 'inet '"
    echo ""
    echo "  # Проверка таблиц маршрутизации"
    echo "  ip route show table all | grep modem"
    echo ""
    echo "  # Проверка конфигурации 3proxy"
    echo "  cat /etc/3proxy/3proxy.cfg | grep proxy"
    echo ""
    echo "  # Логи обработчика модемов"
    echo "  tail -f /var/log/modem-handler.log"
    echo ""
    echo "  # Логи 3proxy"
    echo "  tail -f /var/log/3proxy/3proxy.log"
    echo ""
    echo "  # Ручная синхронизация интерфейсов"
    echo "  systemctl start modem-sync"
    echo ""
    echo "  # Тестирование прокси"
    echo "  curl -x 127.0.0.1:8002 -U viking01:A000000a ifconfig.me"
    echo ""

    log_warn "РЕКОМЕНДУЕТСЯ перезагрузить систему для применения всех изменений:"
    log_warn "  sudo reboot"
}

# Главная функция
main() {
    check_root
    show_welcome
    confirm_installation

    local start_time=$(date +%s)

    # Запуск скриптов установки по порядку
    run_script "1/5" "01-set-limits.sh"
    run_script "2/5" "02-install-3proxy.sh"
    run_script "3/5" "03-configure-network.sh"
    run_script "4/5" "04-setup-udev-rules.sh"
    run_script "5/5" "05-install-sync-service.sh"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    show_completion

    log_info "Время установки: ${duration} секунд"
}

# Обработка Ctrl+C
trap 'log_error "Установка прервана пользователем"; exit 130' INT

main "$@"
