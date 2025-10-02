#!/bin/bash
#
# modem-sync.sh - Синхронизирует все активные интерфейсы модемов при загрузке
# Вызывается systemd service при старте системы
#

set -e

SCRIPT_NAME="modem-sync"
LOGFILE="/var/log/modem-handler.log"
HANDLER="/usr/local/bin/modem-interface-handler.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$SCRIPT_NAME] $1" | tee -a "$LOGFILE"
}

main() {
    log "========================================="
    log "Запуск синхронизации интерфейсов модемов..."

    if [ ! -x "$HANDLER" ]; then
        log "ОШИБКА: Handler скрипт не найден или не исполняемый: $HANDLER"
        exit 1
    fi

    local configured=0
    local failed=0

    # Синхронизируем eth интерфейсы
    for iface in $(ip -o link show | grep -oP 'eth[1-9][0-9]?(?=:)' | grep -E 'eth([1-9]|1[0-9]|20)'); do
        if ip addr show "$iface" 2>/dev/null | grep -q 'inet '; then
            log "Настройка интерфейса: $iface"
            if "$HANDLER" add "$iface" >> "$LOGFILE" 2>&1; then
                ((configured++))
            else
                log "ОШИБКА: Не удалось настроить $iface"
                ((failed++))
            fi
        fi
    done

    # Синхронизируем usb интерфейсы
    for iface in $(ip -o link show | grep -oP 'usb[0-9][0-9]?(?=:)' | grep -E 'usb([0-9]|1[0-9]|20)'); do
        if ip addr show "$iface" 2>/dev/null | grep -q 'inet '; then
            log "Настройка интерфейса: $iface"
            if "$HANDLER" add "$iface" >> "$LOGFILE" 2>&1; then
                ((configured++))
            else
                log "ОШИБКА: Не удалось настроить $iface"
                ((failed++))
            fi
        fi
    done

    log "Синхронизация завершена: настроено=$configured, ошибок=$failed"
    log "========================================="

    if [ $configured -eq 0 ] && [ $failed -eq 0 ]; then
        log "Активные интерфейсы модемов не найдены"
    fi

    exit 0
}

main "$@"
