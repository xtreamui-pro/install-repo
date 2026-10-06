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
apt update && apt upgrade -y
apt install -y ufw fail2ban redis-server ffmpeg wget python3-pip nginx-full

log_title "Configuring nginx"
NGINX_DEFAULT_SITE=/etc/nginx/sites-enabled/default
NGINX_O11_SITE=/etc/nginx/sites-enabled/o11
if [ -f "$NGINX_DEFAULT_SITE" ]; then
  sed -i \
    -e 's/listen 80 default_server;/listen 8080 default_server;/' \
    -e 's/listen \[::\]:80 default_server;/listen [::]:8080 default_server;/' \
    "$NGINX_DEFAULT_SITE"
  log_ok "Nginx default site changed to port 8080"
else
  log_warn "$NGINX_DEFAULT_SITE not found — skipping"
fi

cat <<'EOL' > "$NGINX_O11_SITE"
log_format o11_proxy '$remote_addr - [$time_local] "$request" $status';

server {
  listen 8234;
  listen [::]:8234;

  access_log /var/log/nginx/o11.log o11_proxy;

  location /stream/ {
    access_log off;
    proxy_pass http://127.0.0.1:8283;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host:$server_port;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }

  location / {
    proxy_pass http://127.0.0.1:5454;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host:$server_port;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
EOL
log_ok "Nginx O11 site listens on 8234 and forwards to 127.0.0.1:8283"

nginx -t && systemctl reload nginx

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
su - o11 -c "pip3 install --user --break-system-packages pycurl bs4 curl_cffi redis pywidevine pyplayready requests pytz dnspython requests_toolbelt PySocks cloudscraper lxml"
log_ok "Python packages installed"

log_title "Downloading o11 binaries & config"
wget -q --show-progress https://github.com/xtreamui-pro/install-repo/refs/heads/main/server  -O /home/o11/server
wget -q --show-progress https://github.com/xtreamui-pro/install-repo/refs/heads/main/o11     -O /home/o11/o11
wget -q --show-progress https://github.com/xtreamui-pro/install-repo/refs/heads/main/o11.cfg -O /home/o11/o11.cfg
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
ExecStart=/home/o11/o11 -p 8283 -b 127.0.0.1 -noramfs
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
Environment=O11_API_URL=http://127.0.0.1:8283
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
ufw allow 8234/tcp
echo "y" | sudo ufw enable
log_ok "Firewall rules added"

log_title "Hardening SSH configuration"
SSHD_CONFIG=/etc/ssh/sshd_config
[ -f "${SSHD_CONFIG}.orig" ] || cp "$SSHD_CONFIG" "${SSHD_CONFIG}.orig"

# Set (or replace) a directive in sshd_config, uncommenting it if needed
ensure_sshd_option() {
  option="$1"
  value="$2"
  if grep -qE "^[#[:space:]]*${option}[[:space:]]" "$SSHD_CONFIG"; then
    sed -i -E "s|^[#[:space:]]*${option}[[:space:]].*|${option} ${value}|" "$SSHD_CONFIG"
  else
    echo "${option} ${value}" >> "$SSHD_CONFIG"
  fi
  log_ok "sshd_config: ${option} ${value}"
}

# The account actually used to SSH in (via sudo) — falls back to root
SSH_USER="${SUDO_USER:-root}"
SSH_USER_HOME=$(eval echo "~${SSH_USER}")
USER_HAS_KEY=false
ROOT_HAS_KEY=false
[ -s "${SSH_USER_HOME}/.ssh/authorized_keys" ] && USER_HAS_KEY=true
[ -s /root/.ssh/authorized_keys ] && ROOT_HAS_KEY=true

ensure_sshd_option "LoginGraceTime" "30"
ensure_sshd_option "MaxAuthTries" "3"
ensure_sshd_option "MaxSessions" "2"
ensure_sshd_option "PermitEmptyPasswords" "no"

if [ "$ROOT_HAS_KEY" = true ]; then
  # Root has a working key — keep key-based root login, block root password login
  ensure_sshd_option "PermitRootLogin" "prohibit-password"
else
  log_warn "No SSH key found for root — leaving PermitRootLogin untouched to avoid lockout"
fi

if [ "$USER_HAS_KEY" = true ] || [ "$ROOT_HAS_KEY" = true ]; then
  ensure_sshd_option "PasswordAuthentication" "no"
  log_ok "SSH key login confirmed for '${SSH_USER}' — password authentication disabled"
else
  log_warn "No SSH key found for '${SSH_USER}' or root — leaving PasswordAuthentication enabled to avoid lockout"
fi

if sshd -t; then
  systemctl reload ssh
  log_ok "sshd config validated and reloaded"
else
  log_error "sshd config test failed — reverting to backup"
  cp "${SSHD_CONFIG}.orig" "$SSHD_CONFIG"
fi

log_title "Configuring fail2ban"
cat <<'EOL' > /etc/fail2ban/filter.d/nginx-o11-401.conf
[Definition]
failregex = ^<HOST> - \[.*\] ".*" 401$
ignoreregex =
EOL
log_ok "nginx-o11-401 filter created"

cat <<'EOL' > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = %(sshd_log)s
maxretry = 3
findtime = 10m
bantime = 1y

[o11]
enabled = true
filter = nginx-o11-401
port = 8234
logpath = /var/log/nginx/o11.log
backend = polling
maxretry = 5
findtime = 10m
bantime = 30d
banaction = ufw
EOL
systemctl enable --now fail2ban
systemctl restart fail2ban
log_ok "fail2ban configured and started"


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
printf "${GREEN}${BOLD}➜${NC} Web interface: ${BOLD}http://%s:8234${NC}  ${DIM}(user: admin / pass: 1)${NC}\n" "$PUBLIC_IP"
printf "${RED}${BOLD}IMPORTANT:${NC} ${RED}Change the default admin password after first login!${NC}\n"

# Fix permission issues
log_info "Fixing ownership for /home/o11, /mnt/hls, /mnt/dl"
chown -R o11:o11 /home/o11
chown -R o11:o11 /mnt/hls
chown -R o11:o11 /mnt/dl
log_ok "Done."
