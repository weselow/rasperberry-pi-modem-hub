#!/bin/bash
#
# 01-set-limits.sh - Устанавливает системные лимиты для работы с множеством модемов
# Может запускаться повторно - проверяет существование настроек перед добавлением
#

set -e

SCRIPT_NAME="01-set-limits"
LIMITS_CONF="/etc/security/limits.conf"
SYSCTL_CONF="/etc/sysctl.conf"
SYSTEMD_SYSTEM_CONF="/etc/systemd/system.conf"
SYSTEMD_USER_CONF="/etc/systemd/user.conf"

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

# Функция для настройки systemd system.conf
configure_systemd_system() {
    log_info "Настройка ${SYSTEMD_SYSTEM_CONF}..."

    local changes=0

    # Проверяем существование секции [Manager]
    if ! grep -q "^\[Manager\]" "$SYSTEMD_SYSTEM_CONF" 2>/dev/null; then
        echo "" >> "$SYSTEMD_SYSTEM_CONF"
        echo "[Manager]" >> "$SYSTEMD_SYSTEM_CONF"
        log_info "Добавлена секция [Manager]"
    fi

    add_line_if_missing "$SYSTEMD_SYSTEM_CONF" "DefaultLimitDATA=infinity" "DefaultLimitDATA" && ((changes++))
    add_line_if_missing "$SYSTEMD_SYSTEM_CONF" "DefaultLimitSTACK=infinity" "DefaultLimitSTACK" && ((changes++))
    add_line_if_missing "$SYSTEMD_SYSTEM_CONF" "DefaultLimitCORE=infinity" "DefaultLimitCORE" && ((changes++))
    add_line_if_missing "$SYSTEMD_SYSTEM_CONF" "DefaultLimitRSS=infinity" "DefaultLimitRSS" && ((changes++))
    add_line_if_missing "$SYSTEMD_SYSTEM_CONF" "DefaultLimitNOFILE=500000" "DefaultLimitNOFILE" && ((changes++))
    add_line_if_missing "$SYSTEMD_SYSTEM_CONF" "DefaultLimitAS=infinity" "DefaultLimitAS" && ((changes++))
    add_line_if_missing "$SYSTEMD_SYSTEM_CONF" "DefaultLimitNPROC=500000" "DefaultLimitNPROC" && ((changes++))
    add_line_if_missing "$SYSTEMD_SYSTEM_CONF" "DefaultLimitMEMLOCK=infinity" "DefaultLimitMEMLOCK" && ((changes++))

    if [ $changes -gt 0 ]; then
        log_info "Внесено изменений в ${SYSTEMD_SYSTEM_CONF}: $changes"
        log_warn "Требуется перезагрузка для применения изменений systemd"
    else
        log_info "${SYSTEMD_SYSTEM_CONF} уже настроен"
    fi
}

# Функция для настройки systemd user.conf
configure_systemd_user() {
    log_info "Настройка ${SYSTEMD_USER_CONF}..."

    local changes=0

    # Проверяем существование секции [Manager]
    if ! grep -q "^\[Manager\]" "$SYSTEMD_USER_CONF" 2>/dev/null; then
        echo "" >> "$SYSTEMD_USER_CONF"
        echo "[Manager]" >> "$SYSTEMD_USER_CONF"
        log_info "Добавлена секция [Manager]"
    fi

    add_line_if_missing "$SYSTEMD_USER_CONF" "DefaultLimitDATA=infinity" "DefaultLimitDATA" && ((changes++))
    add_line_if_missing "$SYSTEMD_USER_CONF" "DefaultLimitSTACK=infinity" "DefaultLimitSTACK" && ((changes++))
    add_line_if_missing "$SYSTEMD_USER_CONF" "DefaultLimitCORE=infinity" "DefaultLimitCORE" && ((changes++))
    add_line_if_missing "$SYSTEMD_USER_CONF" "DefaultLimitRSS=infinity" "DefaultLimitRSS" && ((changes++))
    add_line_if_missing "$SYSTEMD_USER_CONF" "DefaultLimitNOFILE=500000" "DefaultLimitNOFILE" && ((changes++))
    add_line_if_missing "$SYSTEMD_USER_CONF" "DefaultLimitAS=infinity" "DefaultLimitAS" && ((changes++))
    add_line_if_missing "$SYSTEMD_USER_CONF" "DefaultLimitNPROC=500000" "DefaultLimitNPROC" && ((changes++))
    add_line_if_missing "$SYSTEMD_USER_CONF" "DefaultLimitMEMLOCK=infinity" "DefaultLimitMEMLOCK" && ((changes++))

    if [ $changes -gt 0 ]; then
        log_info "Внесено изменений в ${SYSTEMD_USER_CONF}: $changes"
    else
        log_info "${SYSTEMD_USER_CONF} уже настроен"
    fi
}

# Главная функция
main() {
    log_info "Начало настройки системных лимитов..."

    check_root

    configure_limits_conf
    configure_sysctl
    configure_systemd_system
    configure_systemd_user

    log_info "Настройка системных лимитов завершена!"
    log_warn "Рекомендуется перезагрузить систему для полного применения всех изменений"
    log_info "Или как минимум: systemctl daemon-reload && exit (новый логин)"
}

main "$@"
