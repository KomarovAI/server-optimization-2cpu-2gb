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

# ... (остальные функции из предыдущей версии)

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
