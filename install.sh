GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()  { printf "${CYAN}==>${NC} %b\n" "$*"; }
log_ok()    { printf "${GREEN}✓${NC} %b\n" "$*"; }
log_warn()  { printf "${BOLD}${CYAN}!${NC} %b\n" "$*"; }
log_error() { printf "${RED}✗${NC} %b\n" "$*" >&2; }
log_dim()   { printf "${DIM}%b${NC}\n" "$*"; }
log_title() { printf "\n${BOLD}${GREEN}%b${NC}\n" "$*"; }

# Helper: append a line to a file only if it isn't already present
ensure_line() {
  line="$1"
  file="$2"
  if grep -qF "$line" "$file" 2>/dev/null; then
    log_dim "  exists in $file → $line"
  else
    echo "$line" >> "$file"
    log_ok "  appended to $file → $line"
  fi
}

log_title "Updating package list and installing dependencies"
# apt update && apt upgrade -y
apt install -y ufw redis-server ffmpeg wget python3-pip

log_title "Tuning kernel & system limits"
ensure_line "fs.file-max = 1048576"               /etc/sysctl.conf
ensure_line "net.core.somaxconn=65535"            /etc/sysctl.conf
ensure_line "net.ipv4.tcp_max_syn_backlog=4096"   /etc/sysctl.conf
ensure_line "o11 soft nofile 1048576"             /etc/security/limits.conf
ensure_line "o11 hard nofile 1048576"             /etc/security/limits.conf
ensure_line "DefaultLimitNOFILE=204890:524288"    /etc/systemd/system.conf
sysctl -p >/dev/null && log_ok "sysctl reloaded"

log_title "Creating user 'o11'"
if id -u o11 >/dev/null 2>&1; then
  log_dim "User 'o11' already exists — skipping"
else
  adduser --disabled-password --shell /bin/bash --gecos "Over-the-Top" o11
  log_ok "User 'o11' created"
fi

log_info "Installing Python packages for 'o11'"
su - o11 -c "pip3 install --user --break-system-packages curl_cffi redis pywidevine pytz bs4 requests pycurl"
log_ok "Python packages installed"

log_title "Downloading o11 binaries & config"
wget -q --show-progress https://github.com/xtreamui-pro/install-repo/raw/refs/heads/o11/server  -O /home/o11/server
wget -q --show-progress https://github.com/xtreamui-pro/install-repo/raw/refs/heads/o11/o11     -O /home/o11/o11
wget -q --show-progress https://github.com/xtreamui-pro/install-repo/raw/refs/heads/o11/o11.cfg -O /home/o11/o11.cfg
chmod +x /home/o11/server /home/o11/o11
log_ok "Binaries placed in /home/o11"

log_title "Setting up tmpfs mounts (/mnt/hls, /mnt/dl)"
mkdir -p /mnt/hls /mnt/dl
ln -sf /mnt/dl  /home/o11/dl
ln -sf /mnt/hls /home/o11/hls

if grep -qF "/mnt/hls" /etc/fstab; then
  log_dim "tmpfs entries already present in /etc/fstab — skipping"
else
  cat <<EOL >> /etc/fstab

tmpfs /mnt/hls tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777,size=70% 0 0
tmpfs /mnt/dl tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777,size=70% 0 0
EOL
  log_ok "tmpfs entries appended to /etc/fstab"
fi

log_title "Installing systemd services"
if [ ! -f /etc/systemd/system/o11.service ]; then
  log_info "Writing /etc/systemd/system/o11.service"
cat <<EOL >> /etc/systemd/system/o11.service
[Unit]
Description=Auto-start O11 Streammer
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
ExecStart=/home/o11/o11 -p 8283 -noramfs
WorkingDirectory=/home/o11/
User=o11
Restart=always
RestartSec=5s

StandardOutput=journal
StandardError=journal
SyslogIdentifier=o11

[Install]
WantedBy=multi-user.target
EOL
  log_ok "o11.service created"
else
  log_dim "/etc/systemd/system/o11.service already exists — skipping"
fi

if [ ! -f /etc/systemd/system/server.service ]; then
  log_info "Writing /etc/systemd/system/server.service"
cat <<EOL >> /etc/systemd/system/server.service
[Unit]
Description=Auto-start O11 Server
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
ExecStart=/home/o11/server
WorkingDirectory=/home/o11/
User=root
Restart=always
RestartSec=5s

StandardOutput=journal
StandardError=journal
SyslogIdentifier=server

[Install]
WantedBy=multi-user.target
EOL
  log_ok "server.service created"
else
  log_dim "/etc/systemd/system/server.service already exists — skipping"
fi


log_title "Enabling & starting services"
systemctl daemon-reload
systemctl enable --now server.service
systemctl enable --now o11.service
log_ok "Services enabled and started"

log_title "Configuring firewall (ufw)"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8283/tcp
log_ok "Firewall rules added"


# Get the server's public IPv4 address
PUBLIC_IP=$(curl -4 -s ifconfig.me)

log_title "Setup finished!"
log_warn "Please ${BOLD}reboot${NC} the system to apply all changes."
log_info "After reboot, check service status with:"
log_dim "  sudo systemctl status o11.service"
log_dim "  sudo systemctl status server.service"
log_info "View logs with:"
log_dim "  journalctl -f -u o11.service"
log_dim "  journalctl -f -u server.service"
printf "${GREEN}${BOLD}➜${NC} Web interface: ${BOLD}http://%s:8283${NC}  ${DIM}(user: admin / pass: 1)${NC}\n" "$PUBLIC_IP"
printf "${RED}${BOLD}IMPORTANT:${NC} ${RED}Change the default admin password after first login!${NC}\n"

# Fix permission issues
log_info "Fixing ownership for /home/o11, /mnt/hls, /mnt/dl"
chown -R o11:o11 /home/o11
chown -R o11:o11 /mnt/hls
chown -R o11:o11 /mnt/dl
log_ok "Done."
