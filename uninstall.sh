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

# Remove a line matching the given fixed string from a file, if present
remove_line() {
  line="$1"
  file="$2"
  if [ -f "$file" ] && grep -qF "$line" "$file"; then
    sed -i "\|$(printf '%s' "$line" | sed 's/[.[\*^$/]/\\&/g')|d" "$file"
    log_ok "  removed from $file → $line"
  fi
}

log_title "Stopping & disabling services"
systemctl disable --now o11.service 2>/dev/null || true
systemctl disable --now server.service 2>/dev/null || true
rm -f /etc/systemd/system/o11.service /etc/systemd/system/server.service
systemctl daemon-reload
log_ok "o11.service and server.service stopped and removed"

log_title "Removing nginx O11 site"
NGINX_DEFAULT_SITE=/etc/nginx/sites-enabled/default
NGINX_O11_SITE=/etc/nginx/sites-enabled/o11
rm -f "$NGINX_O11_SITE"
if [ -f "$NGINX_DEFAULT_SITE" ]; then
  sed -i \
    -e 's/listen 8080 default_server;/listen 80 default_server;/' \
    -e 's/listen \[::\]:8080 default_server;/listen [::]:80 default_server;/' \
    "$NGINX_DEFAULT_SITE"
  log_ok "Nginx default site restored to port 80"
fi
nginx -t 2>/dev/null && systemctl reload nginx || log_warn "nginx reload skipped (not installed or config invalid)"

log_title "Reverting kernel & system limits"
remove_line "fs.file-max = 1048576"             /etc/sysctl.conf
remove_line "net.core.somaxconn=65535"          /etc/sysctl.conf
remove_line "net.ipv4.tcp_max_syn_backlog=4096" /etc/sysctl.conf
remove_line "o11 soft nofile 1048576"           /etc/security/limits.conf
remove_line "o11 hard nofile 1048576"           /etc/security/limits.conf
remove_line "DefaultLimitNOFILE=204890:524288"  /etc/systemd/system.conf
sysctl -p >/dev/null 2>&1 && log_ok "sysctl reloaded"

log_title "Removing tmpfs mounts (/mnt/hls, /mnt/dl)"
umount /mnt/hls 2>/dev/null || true
umount /mnt/dl 2>/dev/null || true
sed -i '/tmpfs \/mnt\/hls tmpfs/d;/tmpfs \/mnt\/dl tmpfs/d' /etc/fstab
rm -f /home/o11/dl /home/o11/hls
log_ok "tmpfs mounts unmounted and fstab entries removed"

log_title "Removing firewall rule"
ufw delete allow 8234/tcp 2>/dev/null || true
log_ok "Port 8234 rule removed (22/80/443 left untouched)"

log_title "Removing fail2ban O11 jail"
rm -f /etc/fail2ban/filter.d/nginx-o11-401.conf
if [ -f /etc/fail2ban/jail.local ]; then
  sed -i '/^\[o11\]/,/^$/d' /etc/fail2ban/jail.local
  log_ok "o11 jail removed from jail.local"
fi
systemctl restart fail2ban 2>/dev/null || true

if [ "$PURGE" = "1" ]; then
  log_title "PURGE=1 set — removing user 'o11' and its data"
  userdel -r o11 2>/dev/null || true
  rm -rf /mnt/hls /mnt/dl
  log_ok "User 'o11', /home/o11, /mnt/hls and /mnt/dl removed"
else
  log_title "Keeping user 'o11' and its data"
  log_dim "Re-run with PURGE=1 (e.g. 'make uninstall PURGE=1') to also delete the 'o11' user, /home/o11, /mnt/hls and /mnt/dl"
fi

log_title "Uninstall finished!"
log_warn "SSH hardening changes in /etc/ssh/sshd_config were left untouched (restore from ${BOLD}sshd_config.orig${NC} manually if needed)."
