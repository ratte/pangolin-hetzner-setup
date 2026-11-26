#!/usr/bin/env bash
# Checks ON the server. Run by test-server.sh via "sudo bash -s".
# Output format per line: STATUS|check|detail   (STATUS = PASS, FAIL or WARN)
set -uo pipefail

pass() { printf 'PASS|%s|%s\n' "$1" "${2:-}"; }
fail() { printf 'FAIL|%s|%s\n' "$1" "${2:-}"; }
warn() { printf 'WARN|%s|%s\n' "$1" "${2:-}"; }
check() { # check "<name>" <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# --- Base system ---------------------------------------------------------------
ci_status="$(cloud-init status 2>/dev/null | awk '/^status:/ {print $2}')"
case "$ci_status" in
  done)     pass "cloud-init finished" "$ci_status" ;;
  degraded) warn "cloud-init finished with warnings" "cloud-init status --long" ;;
  *)        fail "cloud-init finished" "status=${ci_status:-unknown}" ;;
esac
check "Bootstrap finished" test -f /var/lib/pangolin-setup/bootstrap-done
. /etc/os-release && pass "Operating system" "$PRETTY_NAME"

failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs)"
if [[ -z "$failed_units" ]]; then pass "No failed systemd units"
else warn "Failed systemd units" "$failed_units"; fi

disk_used="$(df --output=pcent / | tail -n1 | tr -dc '0-9')"
if (( disk_used < 85 )); then pass "Disk space /" "${disk_used}% used"
else warn "Disk space /" "${disk_used}% used"; fi

if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
  pass "Time sync (NTP)"
else
  warn "Time sync (NTP)" "not synchronized yet"
fi

# --- SSH hardening -------------------------------------------------------------
# shellcheck source=/dev/null
source /etc/pangolin-setup/settings.env 2>/dev/null || true
SSH_PORT="${SSH_PORT:-2222}"
sshd_cfg="$(sshd -T 2>/dev/null)"
grep -qx "port ${SSH_PORT}" <<<"$sshd_cfg" && pass "SSH: Port ${SSH_PORT}" || fail "SSH: Port ${SSH_PORT}" "$(grep '^port ' <<<"$sshd_cfg" | xargs)"
grep -qx 'port 22' <<<"$sshd_cfg" && [[ "$SSH_PORT" != 22 ]] && fail "SSH: port 22 disabled" || pass "SSH: port 22 disabled"
grep -qx 'permitrootlogin no' <<<"$sshd_cfg" && pass "SSH: root login disabled" || fail "SSH: root login disabled"
grep -qx 'passwordauthentication no' <<<"$sshd_cfg" && pass "SSH: password login disabled" || fail "SSH: password login disabled"
grep -qx 'kbdinteractiveauthentication no' <<<"$sshd_cfg" && pass "SSH: keyboard-interactive disabled" || fail "SSH: keyboard-interactive disabled"
check "SSH service active" systemctl is-active --quiet ssh
if [[ "$SSH_PORT" != 22 ]] && systemctl is-active --quiet ssh.socket; then
  fail "ssh.socket disabled" "socket activation still listens on port 22"
else
  pass "ssh.socket disabled"
fi

# --- Firewall (ufw) ------------------------------------------------------------
ufw_status="$(ufw status verbose 2>/dev/null)"
grep -q '^Status: active' <<<"$ufw_status" && pass "ufw active" || fail "ufw active"
grep -q 'deny (incoming)' <<<"$ufw_status" && pass "ufw: incoming blocked by default" || fail "ufw: incoming blocked by default"
for rule in "${SSH_PORT}/tcp" "80/tcp" "443/tcp" "443/udp" "51820/udp" "21820/udp"; do
  if grep -Eq "^${rule}[[:space:]].*ALLOW IN" <<<"$ufw_status"; then
    pass "ufw rule ${rule}"
  else
    fail "ufw rule ${rule}"
  fi
done
pass "Admin networks (SSH)" "${ADMIN_CIDRS:-?}"

# --- fail2ban ------------------------------------------------------------------
check "fail2ban active" systemctl is-active --quiet fail2ban
check "fail2ban responds" fail2ban-client ping
jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
[[ "$jails" == *sshd* ]] && pass "fail2ban jail sshd" "$jails" || fail "fail2ban jail sshd" "${jails:-none}"
[[ "$jails" == *recidive* ]] && pass "fail2ban jail recidive" || fail "fail2ban jail recidive"

# --- Automatic updates ---------------------------------------------------------
check "unattended-upgrades active" systemctl is-active --quiet unattended-upgrades
apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"' \
  && pass "Automatic security updates enabled" \
  || fail "Automatic security updates enabled"

# --- Docker & Pangolin ---------------------------------------------------------
check "Docker active" systemctl is-active --quiet docker
for c in pangolin gerbil traefik; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  restarts="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)"
  if [[ "$state" == "running" ]]; then
    if (( restarts > 3 )); then warn "Container $c running" "but ${restarts} restarts"
    else pass "Container $c running" "restarts: $restarts"; fi
  else
    fail "Container $c running" "status: $state"
  fi
done
health="$(docker inspect -f '{{.State.Health.Status}}' pangolin 2>/dev/null || echo unknown)"
[[ "$health" == "healthy" ]] && pass "Pangolin health check" "$health" || fail "Pangolin health check" "$health"

check "Pangolin API internal (:3001)" docker exec pangolin curl -fsS --max-time 5 http://localhost:3001/api/v1/
check "Traefik Ping (:80/ping)" curl -fsS --max-time 5 http://127.0.0.1/ping
check "Gerbil WireGuard key present" test -s /opt/pangolin/config/key
check "Pangolin database present" test -s /opt/pangolin/config/db/db.sqlite
grep -q '__SERVER_SECRET__' /opt/pangolin/config/config.yml \
  && fail "Server secret set" "placeholder still present" \
  || pass "Server secret set"
perm="$(stat -c '%a' /opt/pangolin/config/config.yml)"
[[ "$perm" == "600" ]] && pass "config.yml readable by root only" || warn "config.yml readable by root only" "permissions: $perm"

if [[ -s /opt/pangolin/config/letsencrypt/acme.json ]] && grep -q '"certificate"' /opt/pangolin/config/letsencrypt/acme.json; then
  pass "Let's Encrypt certificate stored"
else
  warn "Let's Encrypt certificate stored" "no certificate in acme.json yet (check DNS)"
fi

# --- Listening ports -----------------------------------------------------------
listening="$(ss -Hlntu 2>/dev/null)"
for p in "tcp:${SSH_PORT}" tcp:80 tcp:443 udp:51820 udp:21820; do
  proto="${p%%:*}"; port="${p##*:}"
  if awk -v pr="$proto" -v po="$port" '$1==pr && $5 ~ (":" po "$") {f=1} END {exit !f}' <<<"$listening"; then
    pass "Port ${port}/${proto} listening"
  else
    fail "Port ${port}/${proto} listening"
  fi
done
exit 0
