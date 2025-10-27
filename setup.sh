#!/bin/bash

#===============================================================================
# VPS Server Optimization Script for 2 CPU / 2GB RAM
# Оптимизация сервера для конфигурации 2 ядра / 2 ГБ ОЗУ
# Включает установку Docker, Docker Compose и оптимизацию памяти (zram+swap)
# Version: 1.4
#===============================================================================

set -euo pipefail

# Константы
readonly SCRIPT_VERSION="1.4"
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

# ... (setup_logging, log, error_exit, все стандартные функции)

#===============================================================================
# Настройка и автоустановка zram
#===============================================================================
setup_zram() {
    log "INFO" "Setting up zram compression..."
    if modprobe zram 2>/dev/null; then
        log "INFO" "zram kernel module available"
    else
        log "WARN" "zram kernel module NOT found, trying to install linux-modules-extra-$(uname -r)"
        apt-get update
        apt-get install -y linux-modules-extra-$(uname -r)
        if modprobe zram 2>/dev/null; then
            log "INFO" "zram module installed and available"
        else
            log "ERROR" "zram kernel module still unavailable -- skipping zram setup"
            return 0
        fi
    fi
    systemctl stop zramswap 2>/dev/null || true
    if lsblk | grep -q zram; then
        for z in /dev/zram*; do
            if [[ -b "$z" ]] && swapon --show | grep -q "$z"; then
                swapoff "$z" 2>/dev/null || true
            fi
        done
    fi
    cat > /etc/default/zramswap <<EOF
# zram configuration for 2GB RAM server (autogen)
ALLOCATION=${ZRAM_SIZE_MB}
PERCENT=25
PRIORITY=100
ALGO=lz4
EOF
    if systemctl enable zramswap 2>/dev/null && systemctl restart zramswap; then
        if systemctl is-active --quiet zramswap; then
            log "INFO" "zramswap systemd service is active (${ZRAM_SIZE_MB}MB, lz4)"
            return 0
        fi
        log "WARN" "zramswap systemd service is NOT active after restart, trying manual zram setup"
    else
        log "WARN" "zramswap service start failed, trying manual zram setup"
    fi
    modprobe -r zram 2>/dev/null || true
    modprobe zram num_devices=1 2>/dev/null || true
    if [[ -b /dev/zram0 ]]; then
        if [[ -f /sys/block/zram0/comp_algorithm ]] && grep -qw lz4 /sys/block/zram0/comp_algorithm; then
            echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
        fi
        echo "$((ZRAM_SIZE_MB * 1024 * 1024))" > /sys/block/zram0/disksize
        mkswap /dev/zram0 >/dev/null 2>&1 || true
        swapon -p 150 /dev/zram0 >/dev/null 2>&1 || true
        if swapon --show | grep -q "/dev/zram0"; then
            log "INFO" "zram0 is enabled as compressed swap (${ZRAM_SIZE_MB}MB, pri=150)"
            return 0
        else
            log "WARN" "Manual zram setup attempted, but /dev/zram0 is NOT active"
        fi
    else
        log "ERROR" "zram0 block device unavailable even after module install -- skipping zram"
    fi
    log "WARN" "zram could not be enabled; continuing without zram"
}

# ... (остальные функции без изменений)

# main() стандартный
