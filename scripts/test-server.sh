#!/usr/bin/env bash
# Funktionstest der laufenden Maschine: Prüfungen auf dem Server (per SSH) und
# von aussen (Ports, SSH-Härtung, DNS, HTTP/HTTPS, Zertifikat, API).
# Exit-Code 0 = alle Pflichtprüfungen bestanden, 1 = mindestens ein Fehler.
set -uo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd ssh curl dig nc openssl jq

IP="$(server_ip)"; IP6="$(server_ip6)"
[[ -n "$IP" ]] || die "Keine Server-IP im State – zuerst './setup.sh deploy'."
DOMAIN="$DASHBOARD_DOMAIN"
REPORT="$STATE_DIR/test-report-$(date +%Y%m%d-%H%M%S).txt"

n_pass=0; n_fail=0; n_warn=0
result() { # result STATUS NAME DETAIL
  local status="$1" name="$2" detail="${3:-}" mark
  case "$status" in
    PASS) mark="${C_GRN}PASS${C_RST}"; ((n_pass++)) ;;
    FAIL) mark="${C_RED}FAIL${C_RST}"; ((n_fail++)) ;;
    *)    mark="${C_YLW}WARN${C_RST}"; ((n_warn++)) ;;
  esac
  printf '  [%s] %-46s %s\n' "$mark" "$name" "$detail"
  printf '[%s] %s %s\n' "$status" "$name" "$detail" >> "$REPORT"
}
section() { echo; info "$1"; printf '\n## %s\n' "$1" >> "$REPORT"; }

{
  echo "Pangolin-Hetzner-Setup – Testbericht $(date -Is)"
  echo "Server: $IP / $IP6   Dashboard: https://$DOMAIN"
} > "$REPORT"

# --- 1. Prüfungen auf dem Server ------------------------------------------------
section "Prüfungen auf dem Server (SSH als ${ADMIN_USER})"
if remote_out="$(remote 'sudo bash -s' < "$REPO_DIR/scripts/remote-checks.sh" 2>&1)"; then
  while IFS='|' read -r status name detail; do
    [[ "$status" =~ ^(PASS|FAIL|WARN)$ ]] || continue
    result "$status" "$name" "$detail"
  done <<<"$remote_out"
else
  result FAIL "SSH-Verbindung als ${ADMIN_USER}" "$(tail -n1 <<<"$remote_out")"
fi

# --- 2. Von aussen ----------------------------------------------------------------
section "Prüfungen von aussen"

SSH_P="$(server_ssh_port)"
for port in "$SSH_P" 80 443; do
  if nc -z -w 5 "$IP" "$port" 2>/dev/null; then result PASS "TCP-Port $port erreichbar"
  else result FAIL "TCP-Port $port erreichbar"; fi
done
closed_ports=(3000 3001 3002 3004 8080)
[[ "$SSH_P" != 22 ]] && closed_ports=(22 "${closed_ports[@]}")
for port in "${closed_ports[@]}"; do
  if nc -z -w 3 "$IP" "$port" 2>/dev/null; then result FAIL "Port $port geschlossen" "offen!"
  else result PASS "Port $port geschlossen"; fi
done

ssh_opts
root_out="$(ssh "${SSH_OPTS[@]}" "root@$IP" true 2>&1)" \
  && result FAIL "SSH als root abgewiesen" "Login möglich!" \
  || result PASS "SSH als root abgewiesen" "$(tail -n1 <<<"$root_out" | cut -c1-60)"

pw_out="$(ssh "${SSH_OPTS[@]}" -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password,keyboard-interactive \
  "${ADMIN_USER}@$IP" true 2>&1)"
if grep -q 'Permission denied (publickey)' <<<"$pw_out"; then
  result PASS "SSH bietet nur Public-Key-Login an"
else
  result FAIL "SSH bietet nur Public-Key-Login an" "$(tail -n1 <<<"$pw_out" | cut -c1-60)"
fi

# DNS
a_records="$(resolve_a "$DOMAIN" | xargs)"
if grep -qw -- "$IP" <<<"$a_records"; then result PASS "DNS A $DOMAIN → $IP"
else result FAIL "DNS A $DOMAIN → $IP" "gefunden: ${a_records:-nichts}"; fi
aaaa_records="$(resolve_aaaa "$DOMAIN" | xargs)"
if [[ -z "$aaaa_records" ]]; then
  result WARN "DNS AAAA $DOMAIN" "kein AAAA-Record (optional: $IP6)"
elif grep -qiw -- "$IP6" <<<"$aaaa_records"; then
  result PASS "DNS AAAA $DOMAIN → $IP6"
else
  result FAIL "DNS AAAA $DOMAIN → $IP6" "zeigt auf: $aaaa_records"
fi

# HTTP -> HTTPS
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$DOMAIN/" || echo 000)"
[[ "$code" =~ ^30[1278]$ ]] && result PASS "HTTP leitet auf HTTPS um" "HTTP $code" \
  || result FAIL "HTTP leitet auf HTTPS um" "HTTP $code"

# HTTPS-Zertifikat
cert="$(echo | timeout 15 openssl s_client -connect "$IP:443" -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -issuer -enddate 2>/dev/null)"
issuer="$(sed -n 's/^issuer=//p' <<<"$cert")"
enddate="$(sed -n 's/^notAfter=//p' <<<"$cert")"
if [[ -z "$issuer" ]]; then
  result FAIL "TLS-Zertifikat" "kein Zertifikat erhalten"
elif grep -qi 'TRAEFIK DEFAULT CERT' <<<"$issuer"; then
  result FAIL "TLS-Zertifikat von Let's Encrypt" "Traefik-Standardzertifikat (ACME fehlgeschlagen?)"
else
  result PASS "TLS-Zertifikat" "$(cut -c1-50 <<<"$issuer"), gültig bis $enddate"
fi
if curl -fsS -o /dev/null --max-time 15 "https://$DOMAIN/"; then
  result PASS "HTTPS-Dashboard mit gültigem Zertifikat"
else
  result FAIL "HTTPS-Dashboard mit gültigem Zertifikat"
fi

api_body="$(curl -fsS --max-time 15 "https://$DOMAIN/api/v1/" 2>&1)"
if [[ "$(jq -r '.message // empty' <<<"$api_body" 2>/dev/null)" == "Healthy" ]]; then
  result PASS "Pangolin-API über HTTPS" "Healthy"
else
  result FAIL "Pangolin-API über HTTPS" "$(cut -c1-60 <<<"$api_body")"
fi

setup_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN/auth/initial-setup" || echo 000)"
[[ "$setup_code" =~ ^(200|30[1278])$ ]] && result PASS "Seite /auth/initial-setup" "HTTP $setup_code" \
  || result FAIL "Seite /auth/initial-setup" "HTTP $setup_code"

# --- Zusammenfassung -------------------------------------------------------------
echo
summary="Ergebnis: ${n_pass} bestanden, ${n_fail} fehlgeschlagen, ${n_warn} Warnungen"
printf '\n%s\n' "$summary" >> "$REPORT"
if (( n_fail == 0 )); then
  info "${C_GRN}${summary}${C_RST}"
else
  info "${C_RED}${summary}${C_RST}"
fi
echo "  Bericht: $REPORT"
(( n_fail == 0 ))
