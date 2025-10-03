# rasperberry-pi-modem-hub
Скрипты по настройке Raspberry Pi в качестве хоста для модемов E3372

## Подготовка после клонирования

После клонирования репозитория на Linux-системе выполните следующие команды:

### 1. Исправление окончаний строк

Конвертировать файлы из формата Windows (CRLF) в Unix (LF):

```bash
# Установить dos2unix (если не установлен)
sudo apt-get install dos2unix  # Debian/Ubuntu
# или
sudo apk add dos2unix          # Alpine Linux

# Конвертировать все shell-скрипты в репозитории
find . -name "*.sh" -type f -exec dos2unix {} \;
```

Без этого скрипты не будут запускаться с ошибкой `cannot execute: required file not found`.

### 2. Сделать файлы исполняемыми

```bash
# Сделать все .sh файлы исполняемыми
find . -name "*.sh" -type f -exec chmod +x {} \;
```

### 3. Быстрая команда (всё вместе)

```bash
# Установить dos2unix и применить все изменения
sudo apt-get install -y dos2unix && \
find . -name "*.sh" -type f -exec dos2unix {} \; && \
find . -name "*.sh" -type f -exec chmod +x {} \;
```
