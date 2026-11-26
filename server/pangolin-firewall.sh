#!/usr/bin/env bash
# pangolin-firewall – Host-Firewall (ufw) für den Pangolin-Node.
# Verwaltet von pangolin-hetzner-setup. Idempotent, kann jederzeit erneut laufen.
#
# Öffentlich: 80/tcp, 443/tcp, 443/udp (HTTP/3), 51820/udp und 21820/udp (WireGuard).
# SSH (22/tcp): aus ADMIN_CIDRS in /etc/pangolin-setup/settings.env ("any" = überall).
#
# Hinweis: Docker veröffentlicht Container-Ports über eigene iptables-Regeln an ufw
# vorbei. Die ufw-Regeln für 80/443/51820/21820 sind trotzdem gesetzt (IPv6 via
# docker-proxy, Klarheit). Interne Ports (3000–3004, 8080) werden nicht veröffentlicht.
set -euo pipefail

SETTINGS=/etc/pangolin-setup/settings.env
[[ -r "$SETTINGS" ]] || { echo "Fehlt: $SETTINGS" >&2; exit 1; }
# shellcheck source=/dev/null
source "$SETTINGS"
: "${ADMIN_CIDRS:?ADMIN_CIDRS nicht gesetzt}"

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Bisherige Admin-Regeln entfernen (höchste Nummer zuerst).
mapfile -t old_rules < <(ufw status numbered 2>/dev/null \
  | awk -F'[][]' '/# admin-ssh/ { gsub(/ /, "", $2); print $2 }' | sort -rn)
for n in "${old_rules[@]}"; do
  ufw --force delete "$n" >/dev/null
done

# Admin-Zugang (SSH)
for cidr in $ADMIN_CIDRS; do
  if [[ "$cidr" == "any" ]]; then
    ufw allow 22/tcp comment 'admin-ssh' >/dev/null
  else
    ufw allow from "$cidr" to any port 22 proto tcp comment 'admin-ssh' >/dev/null
  fi
done

# Öffentliche Pangolin-Dienste
ufw allow 80/tcp comment 'pangolin-http' >/dev/null
ufw allow 443/tcp comment 'pangolin-https' >/dev/null
ufw allow 443/udp comment 'pangolin-http3' >/dev/null
ufw allow 51820/udp comment 'pangolin-gerbil-wg' >/dev/null
ufw allow 21820/udp comment 'pangolin-clients-wg' >/dev/null

ufw --force enable >/dev/null
ufw status verbose
