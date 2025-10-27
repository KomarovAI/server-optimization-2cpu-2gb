#!/bin/bash
#===============================================================================
# VPS Server Optimization Script for 2 CPU / 2GB RAM + Security
# Оптимизация сервера (2 CPU / 2GB RAM) + базовая безопасность
# Включает Docker, Docker Compose, zram+swap, sysctl, logrotate, мониторинг,
# fail2ban, SSH hardening (root login off, password auth off), опционально UFW.
# Version: 2.0
#===============================================================================

set -euo pipefail

# Константы
readonly SCRIPT_VERSION="2.0"
readonly LOGFILE="/var/log/server-optimization.log"
readonly ZRAM_SIZE_MB=512
readonly SWAP_SIZE_MB=2048
readonly SWAP_FILE="/swapfile"

# Цвета
if [[ -t 1 ]]; then
  readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[1;33m'; readonly BLUE='\033[0;34m'; readonly NC='\033[0m'
else
  readonly RED=''; readonly GREEN=''; readonly YELLOW=''; readonly BLUE=''; readonly NC=''
fi

# Логирование
setup_logging() { touch "$LOGFILE"; exec 1> >(tee -a "$LOGFILE"); exec 2>&1; }
log() { local L="$1"; shift; local ts; ts=$(date '+%Y-%m-%d %H:%M:%S'); case "$L" in
  INFO)  echo -e "${GREEN}[$ts] [INFO]  $*${NC}";;
  WARN)  echo -e "${YELLOW}[$ts] [WARN]  $*${NC}";;
  ERROR) echo -e "${RED}[$ts] [ERROR] $*${NC}";;
  DEBUG) echo -e "${BLUE}[$ts] [DEBUG] $*${NC}";;
esac; }
error_exit(){ local line=${1:-$LINENO}; local code=${2:-1}; log ERROR "Failed at line $line (exit $code)"; exit "$code"; }
trap 'error_exit $LINENO $?' ERR

# Проверки
check_root(){ if [[ $EUID -ne 0 ]]; then log ERROR "Run as root"; exit 1; fi; }
check_system_requirements(){
  log INFO "Checking system requirements..."
  local mem; mem=$(free -m | awk 'NR==2{print $2}'); log INFO "Total RAM: ${mem}MB"
  [[ $mem -lt 1500 ]] && log WARN "Low memory: ${mem}MB. Recommended: 2GB"
  local avail; avail=$(df / | awk 'NR==2{print int($4/1024)}')
  if [[ $avail -lt $SWAP_SIZE_MB ]]; then log ERROR "Low disk: ${avail}MB < ${SWAP_SIZE_MB}MB for swap"; exit 1; fi
  local cores; cores=$(nproc); log INFO "CPU cores: $cores"; [[ $cores -lt 2 ]] && log WARN "Detected 1 core; script optimized for 2+"
  log INFO "System requirements check passed"
}

# Обновление пакетов
update_system(){
  log INFO "Updating packages..."
  apt update -q
  apt install -y curl wget htop git unzip software-properties-common apt-transport-https \
                 ca-certificates gnupg lsb-release zram-tools build-essential
  log INFO "System packages updated successfully"
}

# Docker
install_docker(){
  log INFO "Installing Docker..."
  if command -v docker &>/dev/null; then
    log INFO "Docker already installed ($(docker --version | awk '{print $3}' | tr -d ,))"; return 0
  fi
  apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt update -q
  apt install -y docker-ce docker-ce-cli containerd.io
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "storage-driver": "overlay2",
  "default-ulimits": { "nofile": { "name": "nofile", "hard": 64000, "soft": 64000 } }
}
EOF
  systemctl enable --now docker
  log INFO "Docker installed successfully"; docker --version || true
}

install_docker_compose(){
  log INFO "Installing Docker Compose..."
  if command -v docker-compose &>/dev/null; then
    log INFO "Docker Compose already installed ($(docker-compose --version | awk '{print $3}' | tr -d ,))"; return 0
  fi
  local ver; ver=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f4)
  [[ -z "$ver" ]] && ver="v2.24.0"
  curl -fsSL "https://github.com/docker/compose/releases/download/${ver}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  log INFO "Docker Compose installed: ${ver}"; docker-compose --version || true
}

# ZRAM
setup_zram(){
  log INFO "Setting up zram..."
  if ! modprobe zram 2>/dev/null; then
    log WARN "zram module missing, installing linux-modules-extra-$(uname -r)"
    apt-get update && apt-get install -y "linux-modules-extra-$(uname -r)" || true
    modprobe zram 2>/dev/null || { log ERROR "zram module unavailable; skipping zram"; return 0; }
  fi
  systemctl stop zramswap 2>/dev/null || true
  if lsblk | grep -q zram; then
    for z in /dev/zram*; do [[ -b "$z" ]] && swapon --show | grep -q "$z" && swapoff "$z" || true; done
  fi
  cat > /etc/default/zramswap <<EOF
ALLOCATION=${ZRAM_SIZE_MB}
PERCENT=25
PRIORITY=100
ALGO=lz4
EOF
  if systemctl enable zramswap 2>/dev/null && systemctl restart zramswap && systemctl is-active --quiet zramswap; then
    log INFO "zramswap active (${ZRAM_SIZE_MB}MB, lz4)"; return 0
  fi
  log WARN "zramswap service failed, trying manual zram setup"
  modprobe -r zram 2>/dev/null || true
  modprobe zram num_devices=1 2>/dev/null || true
  if [[ -b /dev/zram0 ]]; then
    [[ -f /sys/block/zram0/comp_algorithm ]] && grep -qw lz4 /sys/block/zram0/comp_algorithm && echo lz4 > /sys/block/zram0/comp_algorithm || true
    echo "$((ZRAM_SIZE_MB * 1024 * 1024))" > /sys/block/zram0/disksize
    mkswap /dev/zram0 >/dev/null 2>&1 || true
    swapon -p 150 /dev/zram0 >/dev/null 2>&1 || true
    if swapon --show | grep -q "/dev/zram0"; then
      log INFO "Manual zram setup OK: /dev/zram0 (${ZRAM_SIZE_MB}MB, pri=150)"; return 0
    fi
  fi
  log WARN "zram could not be enabled; continuing without zram"
}

# SWAP
setup_swap_file(){
  log INFO "Setting up swap file..."
  swapon --show | grep -q "$SWAP_FILE" && swapoff "$SWAP_FILE" || true
  [[ -f "$SWAP_FILE" ]] && rm -f "$SWAP_FILE" || true
  fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw,pri=10 0 0" >> /etc/fstab
  log INFO "Swap file configured successfully"
}

# SYSCTL
optimize_kernel_parameters(){
  log INFO "Optimizing kernel parameters..."
  cat > /etc/sysctl.d/99-server-optimization.conf <<'EOF'
# Memory
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.overcommit_memory=1
vm.overcommit_ratio=50
vm.page-cluster=0
# Network
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
# FS
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
  sysctl -p /etc/sysctl.d/99-server-optimization.conf
  log INFO "Kernel parameters optimized"
}

# SYSTEMD
optimize_systemd_services(){
  log INFO "Disabling unnecessary services..."
  local S=(bluetooth cups cups-browsed ModemManager whoopsie kerneloops speech-dispatcher brltty)
  for svc in "${S[@]}"; do
    systemctl is-enabled "$svc" &>/dev/null && systemctl disable --now "$svc" 2>/dev/null || true
  done
  log INFO "Systemd services optimized"
}

# LOG ROTATION
setup_log_rotation(){
  log INFO "Setting up log rotation..."
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-server-optimization.conf <<'EOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=10M
SystemMaxFiles=10
MaxRetentionSec=7day
Compress=yes
EOF
  systemctl restart systemd-journald
  cat > /etc/logrotate.d/docker <<'EOF'
/var/lib/docker/containers/*/*.log {
  rotate 7
  daily
  compress
  size 10M
  missingok
  delaycompress
  copytruncate
}
EOF
  log INFO "Log rotation configured"
}

# MONITORING
create_monitoring_tools(){
  log INFO "Creating monitoring tools..."
  cat > /root/check-resources.sh <<'EOF'
#!/bin/bash
echo "=== Server Resource Monitoring ==="; date; echo
echo "=== CPU ==="; top -bn1 | grep "Cpu(s)" | awk '{print $2 $3 $4 $5}'; echo
echo "=== Memory ==="; free -h; echo
echo "=== Disk ==="; df -h /; echo
echo "=== Swap ==="; swapon --show; echo
echo "=== Docker ==="
if command -v docker &>/dev/null; then
  docker system df 2>/dev/null || echo "Docker not running"; echo
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "No containers"
else echo "Docker not installed"; fi; echo
echo "=== Network (first 10) ==="; ss -tuln | head -10; echo
echo "=== Load ==="; uptime; echo
echo "=== Top by MEM ==="; ps aux --sort=-%mem | head -5
EOF
  chmod +x /root/check-resources.sh
  cat > /root/docker-status.sh <<'EOF'
#!/bin/bash
echo "=== Docker Status Check ==="
echo "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
echo "Compose: $(docker-compose --version 2>/dev/null || echo 'Not installed')"; echo
docker system info 2>/dev/null | grep -E "(Server Version|Storage Driver|Logging Driver|Cgroup Driver|Memory|CPUs)" || echo "Docker not running"; echo
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "No containers"; echo
docker system df 2>/dev/null || echo "Docker not running"
EOF
  chmod +x /root/docker-status.sh
  log INFO "Monitoring tools created"
}

# DOCKER TEMPLATES
create_docker_compose_template(){
  log INFO "Creating Docker templates..."
  mkdir -p /root/docker-templates/html
  cat > /root/docker-templates/docker-compose.yml <<'EOF'
version: '3.8'
services:
  web:
    image: nginx:alpine
    container_name: web-app
    ports: ["8080:80"]
    volumes: ["./html:/usr/share/nginx/html:ro"]
    restart: unless-stopped
    deploy:
      resources:
        limits: { memory: 128M, cpus: '0.5' }
        reservations: { memory: 64M, cpus: '0.25' }
    environment: [ "TZ=Europe/Moscow" ]
    logging: { driver: "json-file", options: { max-size: "10m", max-file: "3" } }

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
        limits: { memory: 256M, cpus: '0.5' }
        reservations: { memory: 128M, cpus: '0.25' }
    command: >
      postgres -c shared_buffers=64MB -c effective_cache_size=192MB
               -c maintenance_work_mem=16MB -c checkpoint_completion_target=0.9
               -c wal_buffers=4MB -c default_statistics_target=100
               -c random_page_cost=1.1 -c effective_io_concurrency=200
               -c work_mem=2MB -c min_wal_size=1GB -c max_wal_size=4GB
    logging: { driver: "json-file", options: { max-size: "10m", max-file: "3" } }
volumes: { postgres_data: { driver: local } }
networks: { default: { name: app-network, driver: bridge } }
EOF
  cat > /root/docker-templates/html/index.html <<'EOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Server Optimized</title>
<style>body{font-family:Arial;margin:40px;background:#f0f0f0}.c{max-width:600px;margin:0 auto;background:#fff;padding:30px;border-radius:10px}.s{background:#d4edda;padding:15px;border-radius:5px;margin:20px 0}</style>
</head><body><div class="c"><h1>🚀 Optimized Server Ready</h1><div class="s">
✅ 2 CPU / 2GB RAM<br>✅ Docker + Compose<br>✅ zram + swap<br>✅ Sysctl tuned</div><p>Minimal templates are ready.</p></div></body></html>
EOF
  log INFO "Docker templates created"
}

# БЕЗОПАСНОСТЬ
setup_fail2ban(){
  log INFO "Installing and configuring fail2ban..."
  apt install -y fail2ban
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
  log INFO "fail2ban configured"
}

setup_ssh_hardening(){
  log INFO "Applying SSH hardening..."
  local f=/etc/ssh/sshd_config
  cp -a "$f" "${f}.bak.$(date +%s)" || true
  sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' "$f"
  sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$f"
  # Порт можешь изменить вручную; авто-замена рискованна:
  # sed -i 's/^#\?Port .*/Port 2222/' "$f"
  systemctl restart ssh || systemctl restart sshd || true
  log INFO "SSH hardening applied (root login off, password auth off)"
}

# Опционально: UFW (по умолчанию выключено, чтобы не отрезать доступ)
setup_ufw_optional(){
  local ENABLE_UFW="${1:-no}" # yes|no
  if [[ "$ENABLE_UFW" != "yes" ]]; then
    log INFO "UFW skipped (set to 'yes' to enable)"; return 0
  fi
  log INFO "Configuring UFW..."
  apt install -y ufw
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  log INFO "UFW enabled with SSH/HTTP/HTTPS allowed"
}

# ВАЛИДАЦИЯ
validate_installation(){
  log INFO "Starting validation..."
  local failed=0 passed=0 total=0
  check(){ local name="$1" cmd="$2" ok="$3" bad="$4"; ((total++));
    if eval "$cmd" &>/dev/null; then log INFO "✅ $ok"; ((passed++)); else log WARN "⚠️  $bad"; ((failed++)); fi; }
  echo; log INFO "=== SYSTEM VALIDATION REPORT ==="
  check "Docker" "command -v docker && docker --version" \
       "Docker Engine installed" "Docker Engine not installed"
  check "Docker service" "systemctl is-active --quiet docker" \
       "Docker service running" "Docker service not running"
  check "Compose" "command -v docker-compose && docker-compose --version" \
       "Compose installed" "Compose not installed"
  check "Swap file" "test -f '$SWAP_FILE' && swapon --show | grep -q '$SWAP_FILE'" \
       "Swap file active (${SWAP_SIZE_MB}MB)" "Swap file not active"
  check "Swap in fstab" "grep -q '$SWAP_FILE' /etc/fstab" \
       "Swap in /etc/fstab" "Swap not in /etc/fstab"
  check "Sysctl file" "test -f '/etc/sysctl.d/99-server-optimization.conf' && grep -q 'vm.swappiness=10' '/etc/sysctl.d/99-server-optimization.conf'" \
       "Sysctl optimized" "Sysctl file missing or wrong"
  local sw; sw=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo unknown)
  if [[ "$sw" == "10" ]]; then log INFO "✅ Swappiness=10"; ((passed++)); else log WARN "⚠️  Swappiness=$sw"; ((failed++)); fi; ((total++))
  check "Journald conf" "test -f '/etc/systemd/journald.conf.d/99-server-optimization.conf'" \
       "Journald rotation set" "Journald config missing"
  # zram checks
  if systemctl is-enabled --quiet zramswap || swapon --show | grep -q "/dev/zram0"; then
    log INFO "✅ zram present (service or manual)"; ((passed++))
  else
    log WARN "⚠️  zram not active"; ((failed++))
  fi; ((total++))
  # fail2ban
  if systemctl is-enabled --quiet fail2ban; then
    log INFO "✅ fail2ban enabled"; ((passed++))
  else
    log WARN "⚠️  fail2ban not enabled"; ((failed++))
  fi; ((total++))
  # Monitoring scripts
  check "check-resources.sh" "test -x /root/check-resources.sh" \
       "check-resources.sh ok" "check-resources.sh missing"
  check "docker-status.sh" "test -x /root/docker-status.sh" \
       "docker-status.sh ok" "docker-status.sh missing"
  check "docker-compose.yml" "test -f /root/docker-templates/docker-compose.yml" \
       "compose template ok" "compose template missing"
  local free_avail; free_avail=$(free -m | awk 'NR==2{print $7}')
  if [[ "$free_avail" -gt 500 ]]; then log INFO "✅ Available memory: ${free_avail}MB"; ((passed++)); else log WARN "⚠️  Low memory: ${free_avail}MB"; fi; ((total++))
  echo; log INFO "=== VALIDATION SUMMARY ==="
  log INFO "Total: $total | Passed: $passed | Failed: $failed"
  local rate=$((passed * 100 / total))
  if [[ $failed -eq 0 ]]; then log INFO "🎉 SUCCESS ($rate%)"; return 0
  elif [[ $rate -ge 80 ]]; then log WARN "⚠️  MOSTLY SUCCESS ($rate%)"; return 1
  else log ERROR "💥 FAILED ($rate%)"; return 2; fi
}

show_final_success(){
  echo; echo "=================================================================="
  log INFO "🎉🎉🎉 ВСЕ ЗЕБА! СЕРВЕР ГОТОВ К РАБОТЕ! 🎉🎉🎉"
  echo "=================================================================="
  log INFO "🐳 Docker + Compose | 💾 zram ${ZRAM_SIZE_MB}MB + swap ${SWAP_SIZE_MB}MB"
  log INFO "⚙️  Sysctl tuned | 📊 Monitoring | 🗂️  Docker templates | 🛡️  fail2ban"
  log INFO "Commands: /root/check-resources.sh | /root/docker-status.sh | free -h | swapon --show"
  log INFO "Templates: /root/docker-templates/"
  log INFO "Log: $LOGFILE"
  log INFO "💡 Рекомендуется reboot для полной активации zram: sudo reboot"
  echo "=================================================================="
}

main(){
  setup_logging
  log INFO "=== VPS Optimization + Security v${SCRIPT_VERSION} ==="
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
  setup_fail2ban
  setup_ssh_hardening
  setup_ufw_optional "no"   # Поменяй на "yes", если хочешь сразу включить UFW
  echo; log INFO "Running validation..."
  if validate_installation; then
    show_final_success
  else
    log WARN "Validation found warnings; core functionality should work"
  fi
  log INFO "Done at $(date)"
}

main "$@"