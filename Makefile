SHELL := /bin/bash

.PHONY: install uninstall status fail2ban-status-jail fail2ban-unban fail2ban-unban-all whitelist clean-system

# usage: make install  (runs install.sh to set up o11, nginx, fail2ban, ufw, etc.)
install:
	sudo -E bash install.sh

# usage: make uninstall  (reverts install.sh; add PURGE=1 to also delete the o11 user/data)
uninstall:
	sudo -E bash uninstall.sh

status:
	sudo fail2ban-client status sshd
	sudo fail2ban-client status o11

# usage: make fail2ban-status-jail JAIL=sshd
fail2ban-status-jail:
	@if [ -z "$(JAIL)" ]; then echo "Usage: make fail2ban-status-jail JAIL=sshd"; exit 1; fi
	sudo fail2ban-client status $(JAIL)

# usage: make fail2ban-unban IP=1.2.3.4
fail2ban-unban:
	@if [ -z "$(IP)" ]; then echo "Usage: make fail2ban-unban IP=1.2.3.4"; exit 1; fi
	sudo fail2ban-client unban $(IP)

fail2ban-unban-all:
	sudo fail2ban-client unban --all

# usage: make whitelist  (updates fail2ban's ignoreip so IPs in ips.txt are never banned)
whitelist:
	@ips="127.0.0.1/8 ::1"; \
	while IFS= read -r ip; do \
		ip="$${ip%%#*}"; \
		ip="$$(echo $$ip | xargs)"; \
		[ -z "$$ip" ] && continue; \
		ips="$$ips $$ip"; \
	done < ips.txt; \
	sudo sed -i "s|^ignoreip.*|ignoreip = $$ips|" /etc/fail2ban/jail.local
	sudo fail2ban-client reload
	@echo "Whitelist (ignoreip) updated from ips.txt"

# clean log and cache on Ubuntu/Debian
clean-system:
	sudo journalctl --vacuum-time=3d
	sudo apt clean
	sudo apt autoremove -y
	sudo find /var/log -type f -name "*.gz" -delete
	sudo find /var/log -type f -regex ".*\.[0-9]+" -delete
	sudo truncate -s 0 /var/log/*.log 2>/dev/null || true
	rm -rf ~/.cache/*
