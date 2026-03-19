#!/bin/bash
#
# modem-sync.sh - Синхронизирует все активные интерфейсы модемов при загрузке
# Вызывается systemd service при старте системы
#

set -euo pipefail

# Отключаем set -e для основной логики — ошибка одного модема не должна
# прерывать настройку остальных. Контроль ошибок через переменную failed.
set +e

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

    # Ждём завершения обработки udev-событий, чтобы избежать race condition
    log "Ожидание завершения udev-событий..."
    udevadm settle --timeout=30 2>/dev/null || log "Предупреждение: udevadm settle завершился по таймауту"
    log "udev-события обработаны"

    local configured=0
    local failed=0
    local collisions=0

    # Синхронизируем eth интерфейсы
    for iface in $(ip -o link show | grep -oP 'eth[1-9][0-9]?(?=:)' | grep -E 'eth([1-9]|1[0-9]|20)'); do
        if ip addr show "$iface" 2>/dev/null | grep -q 'inet '; then
            log "Настройка интерфейса: $iface"
            local handler_exit=0
            "$HANDLER" add "$iface" >> "$LOGFILE" 2>&1 || handler_exit=$?
            if [ $handler_exit -eq 0 ]; then
                configured=$((configured + 1))
            elif [ $handler_exit -eq 2 ]; then
                collisions=$((collisions + 1))
                log "Интерфейс $iface: коллизия портов (маршрутизация настроена, прокси пропущен)"
            else
                log "ОШИБКА: Не удалось настроить $iface (код: $handler_exit)"
                failed=$((failed + 1))
            fi
        fi
    done

    # Синхронизируем usb интерфейсы
    for iface in $(ip -o link show | grep -oP 'usb[0-9][0-9]?(?=:)' | grep -E 'usb([0-9]|1[0-9]|20)'); do
        if ip addr show "$iface" 2>/dev/null | grep -q 'inet '; then
            log "Настройка интерфейса: $iface"
            local handler_exit=0
            "$HANDLER" add "$iface" >> "$LOGFILE" 2>&1 || handler_exit=$?
            if [ $handler_exit -eq 0 ]; then
                configured=$((configured + 1))
            elif [ $handler_exit -eq 2 ]; then
                collisions=$((collisions + 1))
                log "Интерфейс $iface: коллизия портов (маршрутизация настроена, прокси пропущен)"
            else
                log "ОШИБКА: Не удалось настроить $iface (код: $handler_exit)"
                failed=$((failed + 1))
            fi
        fi
    done

    # Верификация: пересоздание state-файлов для активных интерфейсов без state
    # При flap (remove+add) handler может удалить state, а повторный add — не создать
    log "Проверка state-файлов..."
    local restored=0
    for iface in $(ip -o addr show | grep -oP '(eth[1-9][0-9]?|usb[0-9][0-9]?)(?=:)' | sort -u); do
        local ip
        ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -n1)
        [ -z "$ip" ] && continue

        # Пропускаем не-модемные адреса (не 192.168.x.x)
        echo "$ip" | grep -qP '^192\.168\.' || continue

        # Пропускаем системные подсети (192.168.0.x, 192.168.1.x)
        local subnet
        subnet=$(echo "$ip" | grep -oP '\d+\.\d+\.\d+\.')
        local third_octet
        third_octet=$(echo "$subnet" | grep -oP '\d+\.\d+\.\K\d+')
        [ "$third_octet" = "0" ] || [ "$third_octet" = "1" ] && continue

        # Проверяем наличие state-файлов — если .subnet отсутствует, пересоздаём
        if [ ! -f "/var/run/modem-state/${iface}.subnet" ]; then
            log "Пересоздание state-файлов для $iface (IP: $ip)"
            echo "$ip" > "/var/run/modem-state/${iface}.ip"
            echo "$subnet" > "/var/run/modem-state/${iface}.subnet"
            echo "${subnet}1" > "/var/run/modem-state/${iface}.gateway"
            restored=$((restored + 1))
        fi
    done
    if [ $restored -gt 0 ]; then
        log "Восстановлено state-файлов: $restored"
    fi

    log "Синхронизация завершена: настроено=$configured, коллизий=$collisions, ошибок=$failed"
    log "========================================="

    if [ $configured -eq 0 ] && [ $failed -eq 0 ]; then
        log "Активные интерфейсы модемов не найдены"
    fi

    exit 0
}

main "$@"
