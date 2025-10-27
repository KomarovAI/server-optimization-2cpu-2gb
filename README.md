# Server Optimization for 2 CPU / 2GB RAM

Оптимизированный установочный скрипт для VPS с 2 ядрами и 2 ГБ ОЗУ. Разворачивается одним скриптом и сразу устанавливает Docker и Docker Compose, настраивает zram, swap и параметры ядра.

## Быстрый старт

1. Подключитесь к серверу по SSH под root
2. Выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/KomarovAI/server-optimization-2cpu-2gb/main/setup.sh -o setup.sh \
  && chmod +x setup.sh \
  && sudo ./setup.sh
```

## Что делает скрипт

- Устанавливает Docker и Docker Compose
- Включает zram (512MB) и настраивает swap (2GB)
- Оптимизирует параметры ядра и сети для 2ГБ RAM
- Отключает ненужные сервисы
- Настраивает ротацию логов и journald
- Создает утилиты мониторинга и docker-compose шаблон

## Требования

- Ubuntu 20.04/22.04
- root-доступ
- Свободное место на диске >= 2 ГБ

## Скрипты

- /root/check-resources.sh — мониторинг ресурсов
- /root/docker-status.sh — проверка Docker
- /root/docker-templates/ — шаблон docker-compose с ограничениями ресурсов
