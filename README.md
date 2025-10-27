# VPS Server Optimization для 2 CPU / 2GB RAM

Скрипт автоматической оптимизации VPS сервера под конфигурацию 2 ядра / 2GB RAM с установкой Docker, Docker Compose и максимальной оптимизацией памяти.

## 🚀 Быстрый запуск

### Основная команда (рекомендуется)
```bash
rm -f setup.sh && curl -fsSL https://raw.githubusercontent.com/KomarovAI/server-optimization-2cpu-2gb/efcebd1e664b5081cb75342766dec5d871141da4/setup.sh -o setup.sh && chmod +x setup.sh && sudo ./setup.sh
```

### Альтернативные варианты

**С актуальной версии main (обход кэша):**
```bash
rm -f setup.sh && curl -fsSL "https://raw.githubusercontent.com/KomarovAI/server-optimization-2cpu-2gb/main/setup.sh?cb=$(date +%s)" -o setup.sh && chmod +x setup.sh && sudo ./setup.sh
```

**Прямой запуск без сохранения файла:**
```bash
curl -fsSL "https://raw.githubusercontent.com/KomarovAI/server-optimization-2cpu-2gb/main/setup.sh?cb=$(date +%s)" | sudo bash
```

## ✅ Что установится и настроится

- **🐳 Docker Engine + Docker Compose** - последние стабильные версии
- **💾 zram 512MB** - сжатие оперативной памяти (lz4, приоритет 150)
- **💾 Swap файл 2GB** - файл подкачки с приоритетом 10
- **⚙️ Оптимизация ядра** - sysctl параметры для 2GB RAM (swappiness=10, vfs_cache_pressure=50, BBR TCP, etc.)
- **🔧 Отключение ненужных сервисов** - bluetooth, cups, ModemManager, whoopsie для экономии памяти
- **📊 Утилиты мониторинга** - /root/check-resources.sh, /root/docker-status.sh
- **📝 Логротация** - ограничение размера journald (100MB) и Docker логов
- **🗂️ Docker templates** - готовые compose файлы с лимитами ресурсов

## 📋 Требования

- **ОС:** Ubuntu 20.04/22.04 
- **Права:** root доступ
- **RAM:** минимум 1.5GB (рекомендуется 2GB)
- **Диск:** свободно минимум 2GB для swap
- **Сеть:** доступ к интернету

## 🎯 Результат

В конце установки увидите:
```
🎉🎉🎉 ВСЕ ЗЕБА! СЕРВЕР ГОТОВ К РАБОТЕ! 🎉🎉🎉
✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!
✅ СЕРВЕР ОПТИМИЗИРОВАН ДЛЯ 2 CPU / 2GB RAM!
✅ DOCKER И DOCKER COMPOSE ГОТОВЫ К ИСПОЛЬЗОВАНИЮ!
```

## 📊 Проверка после установки

```bash
/root/check-resources.sh     # мониторинг ресурсов
/root/docker-status.sh       # статус Docker
free -h                      # память и swap
swapon --show               # активные swap устройства
docker --version            # версия Docker
docker-compose --version    # версия Docker Compose
```

## 🔄 Рекомендации

После установки рекомендуется перезагрузка для полной активации всех оптимизаций:
```bash
sudo reboot
```

## 📁 Дополнительно

- **Логи:** `/var/log/server-optimization.log`
- **Docker templates:** `/root/docker-templates/`
- **Конфиги:** `/etc/sysctl.d/99-server-optimization.conf`, `/etc/default/zramswap`

## ⚡ Особенности

- **Автоматическая установка zram модуля** - если отсутствует, скрипт установит linux-modules-extra
- **Устойчивость к ошибкам** - продолжает работу даже при проблемах с отдельными компонентами  
- **Полная валидация** - детальная проверка каждого компонента в конце установки
- **Идемпотентность** - можно запускать повторно без проблем