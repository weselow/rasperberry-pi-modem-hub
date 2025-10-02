# Современная система управления модемами для Raspberry Pi

Система автоматической настройки множественных USB-модемов с использованием **udev + systemd** вместо устаревшего dhcpcd.

## Отличия от старой версии

### Старая версия (dhcpcd)
- ❌ Зависит от dhcpcd (удален из современных Ubuntu/Debian)
- ❌ Хуки dhcpcd не работают в новых системах
- ❌ Требует ручной настройки /etc/dhcpcd.conf

### Новая версия (udev + systemd)
- ✅ Работает в любых современных дистрибутивах
- ✅ Не зависит от конкретного DHCP-клиента
- ✅ Поддерживает NetworkManager, systemd-networkd, dhcpcd
- ✅ Hotplug - автоматическая настройка при подключении/отключении
- ✅ Идемпотентные скрипты - можно запускать повторно
- ✅ Подробное логирование всех операций

## Архитектура

```
┌─────────────────────────────────────────────────────────────┐
│  USB Модемы (Huawei/ZTE) → USB Hub → Raspberry Pi          │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  Kernel создаёт сетевые интерфейсы (eth1-20, usb0-20)      │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  udev правила ловят события ADD/REMOVE интерфейсов          │
│  /etc/udev/rules.d/99-modem-interfaces.rules                │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  modem-interface-handler.sh выполняет:                      │
│  1. Ожидание получения IP от модема (DHCP)                  │
│  2. Настройка таблицы маршрутизации (ip rule/route)         │
│  3. Обновление конфигурации 3proxy                          │
│  4. Перезапуск 3proxy                                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  3proxy слушает порты 8002-8020                             │
│  Каждый порт → свой модем → свой IP-адрес оператора         │
└─────────────────────────────────────────────────────────────┘
```

## Структура проекта

```
modern-setup/
├── install.sh                 # Главный скрипт установки
├── scripts/                   # Скрипты установки
│   ├── 01-set-limits.sh      # Настройка системных лимитов
│   ├── 02-install-3proxy.sh  # Установка и настройка 3proxy
│   ├── 03-configure-network.sh # Настройка сети и таблиц маршрутизации
│   ├── 04-setup-udev-rules.sh # Установка udev правил
│   └── 05-install-sync-service.sh # Установка sync service
├── helpers/                   # Вспомогательные скрипты
│   ├── modem-interface-handler.sh # Обработчик событий модемов
│   └── modem-sync.sh         # Синхронизация при загрузке
├── templates/                 # Шаблоны конфигураций
│   └── modem-sync.service    # Systemd service
└── README.md                  # Этот файл
```

## Быстрый старт

### 1. Установка

```bash
cd /path/to/modern-setup
sudo ./install.sh
```

Скрипт автоматически:
- Установит все зависимости
- Настроит системные лимиты
- Установит и настроит 3proxy
- Настроит таблицы маршрутизации
- Установит udev правила
- Настроит systemd сервисы

### 2. Проверка

После установки подключите модемы и проверьте:

```bash
# Логи обработчика модемов
tail -f /var/log/modem-handler.log

# Список активных интерфейсов
ip addr show | grep 'inet '

# Таблицы маршрутизации
ip route show table all | grep modem

# Конфигурация 3proxy
cat /etc/3proxy/3proxy.cfg | grep proxy

# Статус 3proxy
systemctl status 3proxy
```

### 3. Тестирование прокси

```bash
# Проверка через порт 8002 (модем 192.168.2.x)
curl -x 127.0.0.1:8002 -U viking01:A000000a ifconfig.me

# Проверка через порт 8003 (модем 192.168.3.x)
curl -x 127.0.0.1:8003 -U viking01:A000000a ifconfig.me
```

## Детальная информация

### Как это работает

1. **При подключении модема:**
   - Kernel создаёт интерфейс (eth1, usb0, etc.)
   - udev ловит событие `ACTION=add`
   - Запускается `modem-interface-handler.sh add <interface>`
   - Скрипт ждёт получения IP от модема (до 30 секунд)
   - Настраивает таблицу маршрутизации для интерфейса
   - Добавляет правило в 3proxy.cfg
   - Перезапускает 3proxy

2. **При отключении модема:**
   - udev ловит событие `ACTION=remove`
   - Запускается `modem-interface-handler.sh remove <interface>`
   - Удаляет правила маршрутизации
   - Удаляет строку из 3proxy.cfg
   - Перезапускает 3proxy

3. **При загрузке системы:**
   - Запускается `modem-sync.service`
   - Сканирует все активные интерфейсы
   - Настраивает найденные модемы

### Таблицы маршрутизации

Каждый интерфейс модема получает свою таблицу:

```
# /etc/iproute2/rt_tables
12  modemeth1
13  modemeth2
...
32  modemusb0
33  modemusb1
...
```

Правила маршрутизации:

```bash
# Весь трафик с IP модема идёт через его таблицу
ip rule add from <IP_модема> table modem<интерфейс>

# В таблице один маршрут - gateway модема
ip route add default via <gateway_модема> table modem<интерфейс>
```

### Конфигурация 3proxy

Автоматически генерируется:

```
# Базовая конфигурация создаётся при установке
daemon
users viking01:CL:A000000a
auth cache strong

# Добавляется автоматически при подключении модемов
proxy -n -a -p8002 -e192.168.2.100  # модем в подсети 192.168.2.x
proxy -n -a -p8003 -e192.168.3.100  # модем в подсети 192.168.3.x
...
```

### Поддерживаемые интерфейсы

- **eth1 - eth20** → порты 8002-8020
- **usb0 - usb20** → порты 8002-8020

Подсети:
- `192.168.2.x` → порт 8002
- `192.168.3.x` → порт 8003
- ...
- `192.168.20.x` → порт 8020

Подсети `192.168.0.x` и `192.168.1.x` считаются системными и игнорируются.

## Управление

### Скрипты установки

Все скрипты можно запускать повторно и по отдельности:

```bash
cd modern-setup/scripts

# Только лимиты
sudo ./01-set-limits.sh

# Только 3proxy
sudo ./02-install-3proxy.sh

# Только сеть
sudo ./03-configure-network.sh

# Только udev
sudo ./04-setup-udev-rules.sh

# Только sync service
sudo ./05-install-sync-service.sh
```

### Команды systemd

```bash
# 3proxy
systemctl status 3proxy
systemctl restart 3proxy
systemctl stop 3proxy
systemctl start 3proxy

# modem-sync (синхронизация)
systemctl status modem-sync
systemctl start modem-sync    # Принудительная синхронизация

# Логи
journalctl -u 3proxy -f
journalctl -u modem-sync -f
```

### Ручное управление

```bash
# Ручная настройка интерфейса
/usr/local/bin/modem-interface-handler.sh add eth1

# Ручное удаление интерфейса
/usr/local/bin/modem-interface-handler.sh remove eth1

# Полная синхронизация всех интерфейсов
/usr/local/bin/modem-sync.sh
```

### Логи

```bash
# Основной лог обработчика модемов
tail -f /var/log/modem-handler.log

# Логи 3proxy
tail -f /var/log/3proxy/3proxy.log

# Логи udev (если нужно отладить)
journalctl -f | grep modem
```

## Отладка

### Проверка работы udev

```bash
# Просмотр событий udev в реальном времени
udevadm monitor --environment --udev

# Тест udev правил для интерфейса
udevadm test /sys/class/net/eth1

# Перезагрузка udev правил
udevadm control --reload-rules
udevadm trigger --subsystem-match=net
```

### Проверка маршрутизации

```bash
# Все таблицы маршрутизации
ip route show table all | grep -E 'modem|table'

# Конкретная таблица
ip route show table modemeth1

# Правила маршрутизации
ip rule list | grep modem

# Проверка откуда идёт трафик
ip route get 8.8.8.8 from 192.168.2.100
```

### Проверка 3proxy

```bash
# Проверка портов
netstat -tlnp | grep 3proxy

# Проверка конфигурации
cat /etc/3proxy/3proxy.cfg

# Тест с curl
curl -v -x 127.0.0.1:8002 -U viking01:A000000a http://ifconfig.me
```

## Troubleshooting

### Модем не настраивается автоматически

1. Проверьте логи: `tail -f /var/log/modem-handler.log`
2. Проверьте, что интерфейс получил IP: `ip addr show`
3. Проверьте события udev: `udevadm monitor`
4. Запустите обработчик вручную: `/usr/local/bin/modem-interface-handler.sh add eth1`

### 3proxy не запускается

1. Проверьте статус: `systemctl status 3proxy`
2. Проверьте конфигурацию: `cat /etc/3proxy/3proxy.cfg`
3. Проверьте логи: `tail -f /var/log/3proxy/3proxy.log`
4. Запустите вручную: `/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg`

### Нет интернета через прокси

1. Проверьте маршрутизацию: `ip route show table modemeth1`
2. Проверьте правила: `ip rule list | grep 192.168`
3. Проверьте, что модем имеет интернет: `ping -I eth1 8.8.8.8`
4. Проверьте логи 3proxy: `tail -f /var/log/3proxy/3proxy.log`

### После перезагрузки модемы не работают

1. Проверьте статус сервисов: `systemctl status modem-sync 3proxy`
2. Запустите синхронизацию вручную: `systemctl start modem-sync`
3. Проверьте логи: `tail -f /var/log/modem-handler.log`

## Требования

- Debian/Ubuntu/Raspbian (современные версии)
- Root доступ
- Интернет для скачивания 3proxy (при первой установке)
- USB модемы с поддержкой DHCP

## Совместимость

Протестировано на:
- Raspberry Pi OS (Bullseye, Bookworm)
- Ubuntu 20.04+
- Debian 11+

Поддерживаемые network backends:
- systemd-networkd
- NetworkManager
- dhcpcd (для обратной совместимости)

## Безопасность

Скрипты включают базовые меры безопасности:
- Systemd security settings (NoNewPrivileges, PrivateTmp, etc.)
- Запуск 3proxy от непривилегированного пользователя
- Ограничение прав доступа к конфигурационным файлам

**ВАЖНО:** Измените пароль в `/etc/3proxy/3proxy.cfg` после установки!

## Лицензия

Используйте на своё усмотрение. Скрипты предоставляются "как есть" без гарантий.

## Автор

Обновлённая версия для современных систем на базе udev + systemd.
Оригинальная версия на dhcpcd: github.com/weselow/linux-scripts
