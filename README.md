# VPS Server Optimization + Security для 2 CPU / 2GB RAM

Скрипт автоматической оптимизации VPS сервера под конфигурацию 2 ядра / 2GB RAM с установкой Docker, Docker Compose, максимальной оптимизацией памяти и **базовой безопасностью**.

## 🚀 Быстрый запуск

### Основная команда (рекомендуется)
```bash
rm -f setup.sh && curl -fsSL https://raw.githubusercontent.com/KomarovAI/server-optimization-2cpu-2gb/main/setup.sh -o setup.sh && chmod +x setup.sh && sudo ./setup.sh
```

### Альтернативные варианты

**С фиксированной версии (устойчиво к CDN):**
```bash
rm -f setup.sh && curl -fsSL https://raw.githubusercontent.com/KomarovAI/server-optimization-2cpu-2gb/7413175bea90171acc035db73d14762287f3b69f/setup.sh -o setup.sh && chmod +x setup.sh && sudo ./setup.sh
```

**С актуальной версии main (обход кэша):**
```bash
rm -f setup.sh && curl -fsSL "https://raw.githubusercontent.com/KomarovAI/server-optimization-2cpu-2gb/main/setup.sh?cb=$(date +%s)" -o setup.sh && chmod +x setup.sh && sudo ./setup.sh
```

**Прямой запуск без сохранения файла:**
```bash
curl -fsSL "https://raw.githubusercontent.com/KomarovAI/server-optimization-2cpu-2gb/main/setup.sh?cb=$(date +%s)" | sudo bash
```

## ✅ Что устанавливается и настраивается

### 🔧 Оптимизация производительности
- **🐳 Docker Engine + Docker Compose** - последние стабильные версии
- **💾 zram 512MB** - сжатие оперативной памяти (lz4, приоритет 150)
- **💾 Swap файл 2GB** - файл подкачки с приоритетом 10
- **⚙️ Оптимизация ядра** - sysctl параметры для 2GB RAM (swappiness=10, vfs_cache_pressure=50, BBR TCP, etc.)
- **🔧 Отключение ненужных сервисов** - bluetooth, cups, ModemManager, whoopsie для экономии памяти
- **📊 Утилиты мониторинга** - /root/check-resources.sh, /root/docker-status.sh
- **📝 Логротация** - ограничение размера journald (100MB) и Docker логов
- **🗂️ Docker templates** - готовые compose файлы с лимитами ресурсов

### 🛡️ Безопасность (новое в v2.0)
- **🚫 fail2ban** - автоматическая блокировка брутфорс атак на SSH (5 попыток = бан на 1 час)
- **🔒 SSH hardening** - отключение root login и password authentication
- **🔥 UFW firewall** - опционально (по умолчанию выключен, чтобы не отрезать доступ)
- **🔐 Sysctl безопасности** - защита от сетевых атак

## 📋 Требования

- **ОС:** Ubuntu 20.04/22.04 
- **Права:** root доступ
- **RAM:** минимум 1.5GB (рекомендуется 2GB)
- **Диск:** свободно минимум 2GB для swap
- **Сеть:** доступ к интернету
- **SSH:** доступ по ключам (после установки пароли будут отключены!)

## 🎯 Результат

В конце установки увидите:
```
🎉🎉🎉 ВСЕ ЗЕБА! СЕРВЕР ГОТОВ К РАБОТЕ! 🎉🎉🎉
✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!
✅ СЕРВЕР ОПТИМИЗИРОВАН ДЛЯ 2 CPU / 2GB RAM!
✅ DOCKER И DOCKER COMPOSE ГОТОВЫ К ИСПОЛЬЗОВАНИЮ!
✅ БАЗОВАЯ БЕЗОПАСНОСТЬ НАСТРОЕНА!
```

## 📊 Проверка после установки

### Производительность
```bash
/root/check-resources.sh     # мониторинг ресурсов
/root/docker-status.sh       # статус Docker
free -h                      # память и swap
swapon --show               # активные swap устройства
docker --version            # версия Docker
docker-compose --version    # версия Docker Compose
```

### Безопасность
```bash
fail2ban-client status       # статус fail2ban
fail2ban-client status sshd  # заблокированные IP
systemctl status ssh         # статус SSH
ufw status                   # статус firewall (если включен)
```

## 🔄 Рекомендации

После установки рекомендуется перезагрузка для полной активации всех оптимизаций:
```bash
sudo reboot
```

⚠️ **ВАЖНО:** После установки SSH будет настроен на:
- Отключен вход под root
- Отключена аутентификация по паролю
- Убедитесь, что у вас есть SSH ключи для доступа!

## 📁 Дополнительно

- **Логи:** `/var/log/server-optimization.log`
- **Docker templates:** `/root/docker-templates/`
- **Конфиги:** `/etc/sysctl.d/99-server-optimization.conf`, `/etc/default/zramswap`, `/etc/fail2ban/jail.local`
- **SSH backup:** `/etc/ssh/sshd_config.bak.*`

## ⚡ Особенности v2.0

- **Автоматическая установка zram модуля** - если отсутствует, скрипт установит linux-modules-extra
- **Устойчивость к ошибкам** - продолжает работу даже при проблемах с отдельными компонентами
- **Полная валидация** - детальная проверка каждого компонента в конце установки
- **Идемпотентность** - можно запускать повторно без проблем
- **Безопасность из коробки** - fail2ban и SSH hardening включены по умолчанию
- **Компактный код** - оптимизированный и читаемый bash скрипт

## 🔧 Настройка UFW (опционально)

По умолчанию UFW отключен. Для включения отредактируйте скрипт:
```bash
# Найдите строку:
setup_ufw_optional "no"
# Замените на:
setup_ufw_optional "yes"
```

Или включите UFW вручную после установки:
```bash
sudo ufw enable
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```