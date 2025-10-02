#!/bin/bash
#
# 01-set-limits.sh - Устанавливает системные лимиты для работы с множеством модемов (Alpine Linux)
# Может запускаться повторно - проверяет существование настроек перед добавлением
#

set -e

SCRIPT_NAME="01-set-limits"
LIMITS_CONF="/etc/security/limits.conf"
SYSCTL_CONF="/etc/sysctl.conf"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# Функция для добавления строки в файл, если её там нет
add_line_if_missing() {
    local file="$1"
    local line="$2"
    local comment="$3"

    if ! grep -qF "$line" "$file" 2>/dev/null; then
        if [ ! -f "$file" ]; then
            log_warn "Файл $file не существует, создаём..."
            touch "$file"
        fi

        echo "$line" >> "$file"
        log_info "Добавлено в $file: $line"
        return 0
    else
        log_warn "Уже существует в $file: $comment"
        return 1
    fi
}

# Функция для установки лимитов в /etc/security/limits.conf
configure_limits_conf() {
    log_info "Настройка ${LIMITS_CONF}..."

    # В Alpine может не быть /etc/security/limits.conf по умолчанию
    if [ ! -d "/etc/security" ]; then
        mkdir -p /etc/security
        log_info "Создана директория /etc/security"
    fi

    local changes=0

    add_line_if_missing "$LIMITS_CONF" "* soft nproc 102400" "soft nproc для всех" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "* hard nproc 1000000" "hard nproc для всех" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "* soft nofile 1048576" "soft nofile для всех" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "* hard nofile 1048576" "hard nofile для всех" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "* - memlock unlimited" "memlock для всех" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "* soft sigpending 102400" "soft sigpending для всех" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "* hard sigpending 102400" "hard sigpending для всех" && ((changes++))

    add_line_if_missing "$LIMITS_CONF" "root - memlock unlimited" "root memlock" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "root soft nofile 1048576" "root soft nofile" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "root hard nofile 1048576" "root hard nofile" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "root soft nproc 102400" "root soft nproc" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "root hard nproc 1000000" "root hard nproc" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "root soft sigpending 102400" "root soft sigpending" && ((changes++))
    add_line_if_missing "$LIMITS_CONF" "root hard sigpending 102400" "root hard sigpending" && ((changes++))

    if [ $changes -gt 0 ]; then
        log_info "Внесено изменений в ${LIMITS_CONF}: $changes"
    else
        log_info "${LIMITS_CONF} уже настроен"
    fi
}

# Функция для установки лимитов в /etc/sysctl.conf
configure_sysctl() {
    log_info "Настройка ${SYSCTL_CONF}..."

    local FILE_MAX_VALUE="500000"

    # Удаляем старые записи если есть
    sed -i '/^fs.file-max=/d' "$SYSCTL_CONF" 2>/dev/null || true

    # Добавляем новую запись
    echo "fs.file-max=${FILE_MAX_VALUE}" >> "$SYSCTL_CONF"
    log_info "Установлено fs.file-max=${FILE_MAX_VALUE}"

    # Применяем немедленно
    sysctl -w fs.file-max=${FILE_MAX_VALUE} >/dev/null
    log_info "Применено fs.file-max=${FILE_MAX_VALUE} (runtime)"
}

# Функция для настройки rc.conf (Alpine специфично)
configure_rc_conf() {
    log_info "Настройка /etc/rc.conf для Alpine..."

    local RC_CONF="/etc/rc.conf"

    if [ ! -f "$RC_CONF" ]; then
        log_warn "Файл $RC_CONF не найден, пропускаем"
        return 0
    fi

    # В Alpine можно настроить некоторые лимиты через rc.conf
    # Но основные лимиты уже настроены через limits.conf и sysctl.conf

    log_info "Настройка rc.conf не требуется для базовых лимитов"
}

# Главная функция
main() {
    log_info "Начало настройки системных лимитов (Alpine Linux)..."

    check_root

    configure_limits_conf
    configure_sysctl
    configure_rc_conf

    log_info "Настройка системных лимитов завершена!"
    log_warn "Рекомендуется перезагрузить систему для полного применения всех изменений"
    log_info "Или выйти и зайти снова (для применения limits.conf)"
}

main "$@"
