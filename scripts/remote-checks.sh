#!/usr/bin/env bash
# Prüfungen AUF dem Server. Wird von test-server.sh per "sudo bash -s" ausgeführt.
# Ausgabeformat je Zeile: STATUS|Prüfung|Detail   (STATUS = PASS, FAIL oder WARN)
set -uo pipefail

pass() { printf 'PASS|%s|%s\n' "$1" "${2:-}"; }
fail() { printf 'FAIL|%s|%s\n' "$1" "${2:-}"; }
warn() { printf 'WARN|%s|%s\n' "$1" "${2:-}"; }
check() { # check "<Name>" <Befehl...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# --- Grundsystem ---------------------------------------------------------------
ci_status="$(cloud-init status 2>/dev/null | awk '/^status:/ {print $2}')"
case "$ci_status" in
  done)     pass "cloud-init abgeschlossen" "$ci_status" ;;
  degraded) warn "cloud-init abgeschlossen mit Warnungen" "cloud-init status --long" ;;
  *)        fail "cloud-init abgeschlossen" "status=${ci_status:-unbekannt}" ;;
esac
check "Bootstrap abgeschlossen" test -f /var/lib/pangolin-setup/bootstrap-done
. /etc/os-release && pass "Betriebssystem" "$PRETTY_NAME"

failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs)"
if [[ -z "$failed_units" ]]; then pass "Keine fehlgeschlagenen systemd-Units"
else warn "Fehlgeschlagene systemd-Units" "$failed_units"; fi

disk_used="$(df --output=pcent / | tail -n1 | tr -dc '0-9')"
if (( disk_used < 85 )); then pass "Speicherplatz /" "${disk_used}% belegt"
else warn "Speicherplatz /" "${disk_used}% belegt"; fi

if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
  pass "Zeitsynchronisation (NTP)"
else
  warn "Zeitsynchronisation (NTP)" "noch nicht synchron"
fi

# --- SSH-Härtung ---------------------------------------------------------------
# shellcheck source=/dev/null
source /etc/pangolin-setup/settings.env 2>/dev/null || true
SSH_PORT="${SSH_PORT:-2222}"
sshd_cfg="$(sshd -T 2>/dev/null)"
grep -qx "port ${SSH_PORT}" <<<"$sshd_cfg" && pass "SSH: Port ${SSH_PORT}" || fail "SSH: Port ${SSH_PORT}" "$(grep '^port ' <<<"$sshd_cfg" | xargs)"
grep -qx 'port 22' <<<"$sshd_cfg" && [[ "$SSH_PORT" != 22 ]] && fail "SSH: Port 22 deaktiviert" || pass "SSH: Port 22 deaktiviert"
grep -qx 'permitrootlogin no' <<<"$sshd_cfg" && pass "SSH: root-Login deaktiviert" || fail "SSH: root-Login deaktiviert"
grep -qx 'passwordauthentication no' <<<"$sshd_cfg" && pass "SSH: Passwort-Login deaktiviert" || fail "SSH: Passwort-Login deaktiviert"
grep -qx 'kbdinteractiveauthentication no' <<<"$sshd_cfg" && pass "SSH: Keyboard-Interactive deaktiviert" || fail "SSH: Keyboard-Interactive deaktiviert"
check "SSH-Dienst aktiv" systemctl is-active --quiet ssh
if [[ "$SSH_PORT" != 22 ]] && systemctl is-active --quiet ssh.socket; then
  fail "ssh.socket deaktiviert" "Socket-Aktivierung hört noch auf Port 22"
else
  pass "ssh.socket deaktiviert"
fi

# --- Firewall (ufw) ------------------------------------------------------------
ufw_status="$(ufw status verbose 2>/dev/null)"
grep -q '^Status: active' <<<"$ufw_status" && pass "ufw aktiv" || fail "ufw aktiv"
grep -q 'deny (incoming)' <<<"$ufw_status" && pass "ufw: eingehend standardmässig blockiert" || fail "ufw: eingehend standardmässig blockiert"
for rule in "${SSH_PORT}/tcp" "80/tcp" "443/tcp" "443/udp" "51820/udp" "21820/udp"; do
  if grep -Eq "^${rule}[[:space:]].*ALLOW IN" <<<"$ufw_status"; then
    pass "ufw-Regel ${rule}"
  else
    fail "ufw-Regel ${rule}"
  fi
done
pass "Admin-Netze (SSH)" "${ADMIN_CIDRS:-?}"

# --- fail2ban ------------------------------------------------------------------
check "fail2ban aktiv" systemctl is-active --quiet fail2ban
check "fail2ban antwortet" fail2ban-client ping
jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
[[ "$jails" == *sshd* ]] && pass "fail2ban-Jail sshd" "$jails" || fail "fail2ban-Jail sshd" "${jails:-keine}"
[[ "$jails" == *recidive* ]] && pass "fail2ban-Jail recidive" || fail "fail2ban-Jail recidive"

# --- Automatische Updates ------------------------------------------------------
check "unattended-upgrades aktiv" systemctl is-active --quiet unattended-upgrades
apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"' \
  && pass "Automatische Sicherheitsupdates eingeschaltet" \
  || fail "Automatische Sicherheitsupdates eingeschaltet"

# --- Docker & Pangolin ---------------------------------------------------------
check "Docker aktiv" systemctl is-active --quiet docker
for c in pangolin gerbil traefik; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo fehlt)"
  restarts="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)"
  if [[ "$state" == "running" ]]; then
    if (( restarts > 3 )); then warn "Container $c läuft" "aber ${restarts} Neustarts"
    else pass "Container $c läuft" "Neustarts: $restarts"; fi
  else
    fail "Container $c läuft" "Status: $state"
  fi
done
health="$(docker inspect -f '{{.State.Health.Status}}' pangolin 2>/dev/null || echo unbekannt)"
[[ "$health" == "healthy" ]] && pass "Pangolin Healthcheck" "$health" || fail "Pangolin Healthcheck" "$health"

check "Pangolin-API intern (:3001)" docker exec pangolin curl -fsS --max-time 5 http://localhost:3001/api/v1/
check "Traefik Ping (:80/ping)" curl -fsS --max-time 5 http://127.0.0.1/ping
check "Gerbil WireGuard-Schlüssel vorhanden" test -s /opt/pangolin/config/key
check "Pangolin-Datenbank vorhanden" test -s /opt/pangolin/config/db/db.sqlite
grep -q '__SERVER_SECRET__' /opt/pangolin/config/config.yml \
  && fail "Server-Secret gesetzt" "Platzhalter noch vorhanden" \
  || pass "Server-Secret gesetzt"
perm="$(stat -c '%a' /opt/pangolin/config/config.yml)"
[[ "$perm" == "600" ]] && pass "config.yml nur für root lesbar" || warn "config.yml nur für root lesbar" "Rechte: $perm"

if [[ -s /opt/pangolin/config/letsencrypt/acme.json ]] && grep -q '"certificate"' /opt/pangolin/config/letsencrypt/acme.json; then
  pass "Let's-Encrypt-Zertifikat gespeichert"
else
  warn "Let's-Encrypt-Zertifikat gespeichert" "noch kein Zertifikat in acme.json (DNS prüfen)"
fi

# --- Lauschende Ports ----------------------------------------------------------
listening="$(ss -Hlntu 2>/dev/null)"
for p in "tcp:${SSH_PORT}" tcp:80 tcp:443 udp:51820 udp:21820; do
  proto="${p%%:*}"; port="${p##*:}"
  if awk -v pr="$proto" -v po="$port" '$1==pr && $5 ~ (":" po "$") {f=1} END {exit !f}' <<<"$listening"; then
    pass "Port ${port}/${proto} lauscht"
  else
    fail "Port ${port}/${proto} lauscht"
  fi
done
exit 0
