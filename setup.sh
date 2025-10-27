#!/bin/bash

#===============================================================================
# VPS Server Optimization Script for 2 CPU / 2GB RAM
# Оптимизация сервера для конфигурации 2 ядра / 2 ГБ ОЗУ
# Включает установку Docker, Docker Compose и оптимизацию памяти
# Version: 1.1
#===============================================================================

set -euo pipefail

# Константы
readonly SCRIPT_VERSION="1.1"
readonly LOGFILE="/var/log/server-optimization.log"
readonly ZRAM_SIZE_MB=512   # 512MB zram для экономии памяти
readonly SWAP_SIZE_MB=2048  # 2GB swap для 2GB RAM
readonly SWAP_FILE="/swapfile"

# Цвета для вывода
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly NC=''
fi

#===============================================================================
# Функции логирования
#===============================================================================

setup_logging() {
    touch "$LOGFILE"
    exec 1> >(tee -a "$LOGFILE")
    exec 2>&1
}

log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "INFO")  echo -e "${GREEN}[$timestamp] [INFO]  $*${NC}" ;;
        "WARN")  echo -e "${YELLOW}[$timestamp] [WARN]  $*${NC}" ;;
        "ERROR") echo -e "${RED}[$timestamp] [ERROR] $*${NC}" ;;
        "DEBUG") echo -e "${BLUE}[$timestamp] [DEBUG] $*${NC}" ;;
    esac
}

error_exit() {
    local line_no=${1:-$LINENO}
    local exit_code=${2:-1}
    log "ERROR" "Script failed at line $line_no with exit code $exit_code"
    exit "$exit_code"
}

trap 'error_exit $LINENO $?' ERR

#===============================================================================
# Проверки системы
#===============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
}

check_system_requirements() {
    log "INFO" "Checking system requirements..."
    
    # Проверка доступной памяти
    local total_mem_mb
    total_mem_mb=$(free -m | awk 'NR==2{print $2}')
    
    log "INFO" "Total RAM: ${total_mem_mb}MB"
    
    if [[ $total_mem_mb -lt 1500 ]]; then
        log "WARN" "Low system memory detected: ${total_mem_mb}MB. Recommended: 2GB"
    fi
    
    # Проверка доступного дискового пространства
    local available_space_mb
    available_space_mb=$(df / | awk 'NR==2 {print int($4/1024)}')
    
    if [[ $available_space_mb -lt $SWAP_SIZE_MB ]]; then
        log "ERROR" "Insufficient disk space for swap. Available: ${available_space_mb}MB, Required: ${SWAP_SIZE_MB}MB"
        exit 1
    fi
    
    # Проверка количества CPU ядер
    local cpu_cores
    cpu_cores=$(nproc)
    log "INFO" "CPU cores: $cpu_cores"
    
    if [[ $cpu_cores -lt 2 ]]; then
        log "WARN" "Single core CPU detected. This script is optimized for 2+ cores"
    fi
    
    log "INFO" "System requirements check passed"
}

#===============================================================================
# Обновление системы и установка базовых пакетов
#===============================================================================

update_system() {
    log "INFO" "Updating system packages..."
    
    # Обновление списка пакетов
    apt update -q
    
    # Установка базовых пакетов
    local base_packages=(
        "curl" "wget" "htop" "git" "unzip"
        "software-properties-common" "apt-transport-https"
        "ca-certificates" "gnupg" "lsb-release"
        "zram-tools" "build-essential"
    )
    
    apt install -y "${base_packages[@]}"
    
    log "INFO" "System packages updated successfully"
}

#===============================================================================
# Установка Docker и Docker Compose
#===============================================================================

install_docker() {
    log "INFO" "Installing Docker..."
    
    # Проверка существующей установки
    if command -v docker &>/dev/null; then
        local current_version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        log "INFO" "Docker already installed (version: $current_version)"
        return 0
    fi
    
    # Удаление старых версий если есть
    apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Добавление официального GPG ключа Docker
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Добавление репозитория Docker
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Обновление индекса пакетов
    apt update -q
    
    # Установка Docker Engine
    apt install -y docker-ce docker-ce-cli containerd.io
    
    # Настройка Docker daemon для оптимизации памяти
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "default-ulimits": {
        "nofile": {
            "name": "nofile",
            "hard": 64000,
            "soft": 64000
        }
    }
}
EOF
    
    # Запуск Docker
    systemctl enable --now docker
    
    log "INFO" "Docker installed successfully"
    docker --version
}

install_docker_compose() {
    log "INFO" "Installing Docker Compose..."
    
    # Проверка существующей установки
    if command -v docker-compose &>/dev/null; then
        local current_version=$(docker-compose --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        log "INFO" "Docker Compose already installed (version: $current_version)"
        return 0
    fi
    
    # Получение последней версии
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d '"' -f4)
    
    if [[ -z "$latest_version" ]]; then
        log "WARN" "Could not get latest version, using fallback"
        latest_version="v2.24.0"
    fi
    
    # Скачивание и установка
    local compose_url="https://github.com/docker/compose/releases/download/${latest_version}/docker-compose-$(uname -s)-$(uname -m)"
    
    curl -L "$compose_url" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    # Создание symlink для удобства
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    log "INFO" "Docker Compose installed: $latest_version"
    docker-compose --version
}

#===============================================================================
# Оптимизация памяти
#===============================================================================

setup_zram() {
    log "INFO" "Setting up zram compression..."
    
    # Остановка существующих zram устройств
    systemctl stop zramswap 2>/dev/null || true
    
    # Отключение существующих zram устройств
    for zram_dev in /dev/zram*; do
        if [[ -b "$zram_dev" ]] && swapon --show | grep -q "$zram_dev"; then
            log "INFO" "Disabling existing zram device: $zram_dev"
            swapoff "$zram_dev" 2>/dev/null || true
        fi
    done
    
    # Конфигурация zram
    cat > /etc/default/zramswap <<EOF
# zram configuration for 2GB RAM server
ALLOCATION=${ZRAM_SIZE_MB}
PERCENT=25
PRIORITY=100
ALGO=lz4
EOF
    
    # Включение и запуск zramswap
    systemctl enable zramswap
    systemctl restart zramswap
    
    log "INFO" "zram configured successfully (${ZRAM_SIZE_MB}MB)"
}

setup_swap_file() {
    log "INFO" "Setting up swap file..."
    
    # Отключение существующего swap если есть
    if swapon --show | grep -q "$SWAP_FILE"; then
        log "INFO" "Disabling existing swap file"
        swapoff "$SWAP_FILE"
    fi
    
    # Удаление старого swap файла
    [[ -f "$SWAP_FILE" ]] && rm -f "$SWAP_FILE"
    
    # Создание нового swap файла
    log "INFO" "Creating ${SWAP_SIZE_MB}MB swap file..."
    
    # Используем fallocate для быстрого создания
    fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" || \
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
    
    # Установка правильных прав
    chmod 600 "$SWAP_FILE"
    
    # Создание и активация swap
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    
    # Добавление в fstab
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw,pri=10 0 0" >> /etc/fstab
    fi
    
    log "INFO" "Swap file configured successfully"
}

optimize_kernel_parameters() {
    log "INFO" "Optimizing kernel parameters for 2GB RAM..."
    
    # Создание файла оптимизации
    cat > /etc/sysctl.d/99-server-optimization.conf <<EOF
# Server optimization for 2 CPU / 2GB RAM configuration

# Memory Management
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.overcommit_memory=1
vm.overcommit_ratio=50
vm.page-cluster=0

# Network Optimization
net.core.rmem_default=262144
net.core.rmem_max=16777216
net.core.wmem_default=262144
net.core.wmem_max=16777216
net.core.netdev_max_backlog=5000
net.core.somaxconn=4096
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_rmem=4096 65536 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1

# File System Optimization
fs.file-max=2097152
fs.nr_open=1048576

# Security
kernel.dmesg_restrict=1
net.ipv4.conf.default.log_martians=1
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.ip_forward=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
EOF
    
    # Применение настроек
    sysctl -p /etc/sysctl.d/99-server-optimization.conf
    
    log "INFO" "Kernel parameters optimized"
}

#===============================================================================
# Дополнительные оптимизации
#===============================================================================

optimize_systemd_services() {
    log "INFO" "Optimizing systemd services..."
    
    # Отключение ненужных сервисов для экономии памяти
    local services_to_disable=(
        "bluetooth"
        "cups"
        "cups-browsed"
        "ModemManager"
        "whoopsie"
        "kerneloops"
        "speech-dispatcher"
        "brltty"
    )
    
    for service in "${services_to_disable[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            log "INFO" "Disabling service: $service"
            systemctl disable --now "$service" 2>/dev/null || true
        fi
    done
    
    log "INFO" "Systemd services optimized"
}

setup_log_rotation() {
    log "INFO" "Setting up log rotation..."
    
    # Ограничение размера журнала systemd
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-server-optimization.conf <<EOF
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=10M
SystemMaxFiles=10
MaxRetentionSec=7day
Compress=yes
EOF
    
    systemctl restart systemd-journald
    
    # Настройка logrotate для Docker
    cat > /etc/logrotate.d/docker <<EOF
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    size=10M
    missingok
    delaycompress
    copytruncate
}
EOF
    
    log "INFO" "Log rotation configured"
}

#===============================================================================
# Мониторинг и утилиты
#===============================================================================

create_monitoring_tools() {
    log "INFO" "Creating monitoring tools..."
    
    # Скрипт проверки ресурсов
    cat > /root/check-resources.sh <<'EOF'
#!/bin/bash

echo "=== Server Resource Monitoring ==="
echo "Date: $(date)"
echo

echo "=== CPU Usage ==="
top -bn1 | grep "Cpu(s)" | awk '{print $2 $3 $4 $5}'

echo
echo "=== Memory Usage ==="
free -h

echo
echo "=== Disk Usage ==="
df -h /

echo
echo "=== Swap Usage ==="
swapon --show

echo
echo "=== Docker Status ==="
if command -v docker &>/dev/null; then
    docker system df 2>/dev/null || echo "Docker not running"
    echo
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "No containers running"
else
    echo "Docker not installed"
fi

echo
echo "=== Network Connections ==="
ss -tuln | head -10

echo
echo "=== Load Average ==="
uptime

echo
echo "=== Top Processes by Memory ==="
ps aux --sort=-%mem | head -5
EOF
    
    chmod +x /root/check-resources.sh
    
    # Скрипт быстрой проверки Docker
    cat > /root/docker-status.sh <<'EOF'
#!/bin/bash

echo "=== Docker Status Check ==="
echo "Docker Version: $(docker --version 2>/dev/null || echo 'Not installed')"
echo "Docker Compose Version: $(docker-compose --version 2>/dev/null || echo 'Not installed')"
echo

echo "=== Docker System Info ==="
docker system info 2>/dev/null | grep -E "(Server Version|Storage Driver|Logging Driver|Cgroup Driver|Memory|CPUs)" || echo "Docker not running"
echo

echo "=== Running Containers ==="
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "No containers running"
echo

echo "=== Docker Resource Usage ==="
docker system df 2>/dev/null || echo "Docker not running"
EOF
    
    chmod +x /root/docker-status.sh
    
    log "INFO" "Monitoring tools created:"
    log "INFO" "  - /root/check-resources.sh"
    log "INFO" "  - /root/docker-status.sh"
}

create_docker_compose_template() {
    log "INFO" "Creating Docker Compose templates..."
    
    mkdir -p /root/docker-templates
    
    # Базовый template
    cat > /root/docker-templates/docker-compose.yml <<'EOF'
version: '3.8'

services:
  # Пример веб-приложения с ограничениями ресурсов для 2GB RAM сервера
  web:
    image: nginx:alpine
    container_name: web-app
    ports:
      - "8080:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: '0.5'
        reservations:
          memory: 64M
          cpus: '0.25'
    environment:
      - TZ=Europe/Moscow
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # Пример базы данных с оптимизацией для малого объема памяти
  db:
    image: postgres:15-alpine
    container_name: postgres-db
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d:ro
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '0.5'
        reservations:
          memory: 128M
          cpus: '0.25'
    command: >
      postgres
      -c shared_buffers=64MB
      -c effective_cache_size=192MB
      -c maintenance_work_mem=16MB
      -c checkpoint_completion_target=0.9
      -c wal_buffers=4MB
      -c default_statistics_target=100
      -c random_page_cost=1.1
      -c effective_io_concurrency=200
      -c work_mem=2MB
      -c min_wal_size=1GB
      -c max_wal_size=4GB
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  postgres_data:
    driver: local

networks:
  default:
    name: app-network
    driver: bridge
EOF
    
    # Создание примера HTML страницы
    mkdir -p /root/docker-templates/html
    cat > /root/docker-templates/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Server Optimized for 2CPU/2GB</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f0f0f0; }
        .container { max-width: 600px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; }
        .status { background: #d4edda; padding: 15px; border-radius: 5px; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Optimized Server Ready</h1>
        <div class="status">
            ✅ Server optimized for 2 CPU cores and 2GB RAM<br>
            ✅ Docker and Docker Compose installed<br>
            ✅ Memory optimization configured<br>
            ✅ zram compression enabled
        </div>
        <p>This server has been optimized for efficient resource usage.</p>
    </div>
</body>
</html>
EOF
    
    log "INFO" "Docker Compose template created at /root/docker-templates/"
}

#===============================================================================
# Детальная валидация установки
#===============================================================================
validate_installation() {
    log "INFO" "Starting comprehensive installation validation..."
    
    local validation_failed=0
    local checks_passed=0
    local total_checks=0
    
    check_component() {
        local component="$1"
        local check_command="$2"
        local success_message="$3"
        local failure_message="$4"
        ((total_checks++))
        log "DEBUG" "Checking: $component"
        if eval "$check_command" &>/dev/null; then
            log "INFO" "✅ $success_message"
            ((checks_passed++))
            return 0
        else
            log "ERROR" "❌ $failure_message"
            ((validation_failed++))
            return 1
        fi
    }
    echo
    log "INFO" "=== SYSTEM VALIDATION REPORT ==="
    check_component "Docker Engine" "command -v docker && docker --version" "Docker Engine is installed and working" "Docker Engine is not properly installed"
    check_component "Docker Service" "systemctl is-active --quiet docker" "Docker service is running" "Docker service is not running"
    check_component "Docker Permissions" "docker info" "Docker daemon is accessible" "Docker daemon is not accessible"
    check_component "Docker Compose" "command -v docker-compose && docker-compose --version" "Docker Compose is installed and working" "Docker Compose is not properly installed"
    check_component "zram Service" "systemctl is-enabled --quiet zramswap" "zramswap service is enabled" "zramswap service is not enabled"
    if systemctl is-active --quiet zramswap; then
        log "INFO" "✅ zramswap service is running"
        ((checks_passed++))
    else
        log "WARN" "⚠️  zramswap service not running (may need reboot)"
    fi
    ((total_checks++))
    check_component "Swap File" "test -f '$SWAP_FILE' && swapon --show | grep -q '$SWAP_FILE'" "Swap file is created and active (${SWAP_SIZE_MB}MB)" "Swap file is not properly configured"
    check_component "Swap in fstab" "grep -q '$SWAP_FILE' /etc/fstab" "Swap file is registered in /etc/fstab" "Swap file is not in /etc/fstab"
    local sysctl_file="/etc/sysctl.d/99-server-optimization.conf"
    check_component "Sysctl Config" "test -f '$sysctl_file' && grep -q 'vm.swappiness=10' '$sysctl_file'" "Kernel parameters optimized" "Kernel parameters not properly configured"
    local current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")
    if [[ "$current_swappiness" == "10" ]]; then
        log "INFO" "✅ Swappiness is set to 10 (optimal)"
        ((checks_passed++))
    else
        log "WARN" "⚠️  Swappiness is $current_swappiness (should be 10)"
        ((validation_failed++))
    fi
    ((total_checks++))
    check_component "Journald Config" "test -f '/etc/systemd/journald.conf.d/99-server-optimization.conf'" "Journald log rotation configured" "Journald configuration missing"
    local disabled_count=0
    local services_to_check=("bluetooth" "cups" "ModemManager" "whoopsie")
    for service in "${services_to_check[@]}"; do
        if ! systemctl is-enabled "$service" &>/dev/null; then
            ((disabled_count++))
        fi
    done
    if [[ $disabled_count -gt 0 ]]; then
        log "INFO" "✅ $disabled_count unnecessary services disabled"
        ((checks_passed++))
    else
        log "WARN" "⚠️  No unnecessary services were disabled"
    fi
    ((total_checks++))
    local monitoring_scripts=("/root/check-resources.sh" "/root/docker-status.sh")
    for script in "${monitoring_scripts[@]}"; do
        check_component "Monitoring Script $(basename "$script")" "test -x '$script'" "$(basename "$script") is executable" "$(basename "$script") is missing or not executable"
    done
    check_component "Docker Template" "test -f '/root/docker-templates/docker-compose.yml'" "Docker Compose template created" "Docker Compose template missing"
    local available_mem_mb=$(free -m | awk 'NR==2{print $7}')
    if [[ $available_mem_mb -gt 500 ]]; then
        log "INFO" "✅ Available memory: ${available_mem_mb}MB (good)"
        ((checks_passed++))
    else
        log "WARN" "⚠️  Available memory: ${available_mem_mb}MB (low)"
    fi
    ((total_checks++))
    echo
    log "INFO" "=== VALIDATION SUMMARY ==="
    log "INFO" "Total checks: $total_checks"
    log "INFO" "Passed: $checks_passed"
    log "INFO" "Failed: $validation_failed"
    local success_rate=$((checks_passed * 100 / total_checks))
    if [[ $validation_failed -eq 0 ]]; then
        log "INFO" "🎉 VALIDATION RESULT: SUCCESS (100%)"
        log "INFO" "🚀 All components installed and configured correctly!"
        return 0
    elif [[ $success_rate -ge 80 ]]; then
        log "WARN" "⚠️  VALIDATION RESULT: MOSTLY SUCCESS (${success_rate}%)"
        log "WARN" "Most components working, but $validation_failed issues detected"
        return 1
    else
        log "ERROR" "💥 VALIDATION RESULT: FAILED (${success_rate}%)"
        log "ERROR" "Multiple critical components failed validation"
        return 2
    fi
}

show_final_success_message() {
    echo
    echo "=================================================================="
    log "INFO" "🎉🎉🎉 ВСЕ ЗЕБА! СЕРВЕР ГОТОВ К РАБОТЕ! 🎉🎉🎉"
    echo "=================================================================="
    echo
    log "INFO" "📋 Что установлено и настроено:"
    log "INFO" "   🐳 Docker Engine + Docker Compose"
    log "INFO" "   💾 zram (${ZRAM_SIZE_MB}MB) + swap (${SWAP_SIZE_MB}MB)"
    log "INFO" "   ⚙️  Оптимизация ядра для 2GB RAM"
    log "INFO" "   📊 Скрипты мониторинга"
    log "INFO" "   🗂️  Docker templates с лимитами ресурсов"
    echo
    log "INFO" "🚀 Команды для проверки:"
    log "INFO" "   /root/check-resources.sh     - проверка ресурсов"
    log "INFO" "   /root/docker-status.sh       - статус Docker"
    log "INFO" "   docker --version             - версия Docker"
    log "INFO" "   docker-compose --version     - версия Docker Compose"
    log "INFO" "   free -h                      - память и swap"
    log "INFO" "   swapon --show               - активные swap устройства"
    echo
    log "INFO" "📁 Docker templates: /root/docker-templates/"
    log "INFO" "📋 Полный лог: $LOGFILE"
    echo
    log "INFO" "💡 Рекомендация: перезагрузите сервер для полной активации zram"
    log "INFO" "   sudo reboot"
    echo
    echo "=================================================================="
    log "INFO" "✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
    log "INFO" "✅ СЕРВЕР ОПТИМИЗИРОВАН ДЛЯ 2 CPU / 2GB RAM!"
    log "INFO" "✅ DOCKER И DOCKER COMPOSE ГОТОВЫ К ИСПОЛЬЗОВАНИЮ!"
    echo "=================================================================="
}

main() {
    setup_logging
    log "INFO" "=== VPS Server Optimization Script v${SCRIPT_VERSION} ==="
    log "INFO" "Target: 2 CPU cores / 2GB RAM with Docker optimization"
    check_root
    check_system_requirements
    update_system
    install_docker
    install_docker_compose
    setup_zram
    setup_swap_file
    optimize_kernel_parameters
    optimize_systemd_services
    setup_log_rotation
    create_monitoring_tools
    create_docker_compose_template
    echo
    log "INFO" "🔍 Запуск валидации установки..."
    if validate_installation; then
        show_final_success_message
        log "INFO" "🎯 Все компоненты работают корректно!"
    else
        log "WARN" "⚠️  Некоторые компоненты требуют внимания"
        log "INFO" "📋 Проверьте лог выше для деталей"
        log "INFO" "🔧 Несмотря на предупреждения, основная функциональность должна работать"
    fi
    log "INFO" "Server optimization script completed at $(date)!"
}

main "$@"