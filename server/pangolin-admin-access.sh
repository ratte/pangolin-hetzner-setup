#!/usr/bin/env bash
# pangolin-admin-access – SSH-Zugang auf bestimmte Netze einschränken, mit
# automatischem Rollback, falls die Bestätigung ausbleibt.
#
#   pangolin-admin-access show
#   pangolin-admin-access set "203.0.113.10/32 2001:db8::/48"   # oder "any"
#   pangolin-admin-access confirm      # neue Regeln behalten
#   pangolin-admin-access rollback     # vorherige Regeln wiederherstellen
#
# Nach "set" wird nach ROLLBACK_SECONDS automatisch zurückgerollt, wenn nicht
# "confirm" (aus einer NEUEN SSH-Verbindung) aufgerufen wird.
set -euo pipefail

SETTINGS=/etc/pangolin-setup/settings.env
BACKUP=/etc/pangolin-setup/settings.env.bak
UNIT=pangolin-admin-rollback
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-180}"

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }

valid_cidr() {
  local c="$1"
  [[ "$c" == "any" ]] && return 0
  python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$c" 2>/dev/null
}

cancel_timer() {
  systemctl stop "${UNIT}.timer" 2>/dev/null || true
  systemctl reset-failed "${UNIT}.timer" "${UNIT}.service" 2>/dev/null || true
}

cmd="${1:-show}"
case "$cmd" in
  show)
    grep '^ADMIN_CIDRS=' "$SETTINGS"
    ufw status | grep -E 'admin-ssh' || true
    ;;
  set)
    new="${2:-}"
    [[ -n "$new" ]] || { echo "Verwendung: $0 set \"<cidr> [<cidr> ...]|any\"" >&2; exit 2; }
    for c in $new; do
      valid_cidr "$c" || { echo "Ungültiges Netz: $c" >&2; exit 2; }
    done
    if [[ " $new " == *" any "* ]] && [[ "$new" != "any" ]]; then
      echo "\"any\" darf nicht mit weiteren Netzen kombiniert werden." >&2; exit 2
    fi
    cancel_timer
    # Bestehendes Backup (letzter bestätigter Stand) nicht überschreiben.
    [[ -f "$BACKUP" ]] || cp -p "$SETTINGS" "$BACKUP"
    tmp="$(mktemp)"
    sed "s|^ADMIN_CIDRS=.*|ADMIN_CIDRS=\"${new}\"|" "$SETTINGS" > "$tmp"
    cat "$tmp" > "$SETTINGS"
    rm -f "$tmp"
    /usr/local/sbin/pangolin-firewall >/dev/null
    systemd-run --quiet --unit="$UNIT" --on-active="${ROLLBACK_SECONDS}" \
      /usr/local/sbin/pangolin-admin-access rollback
    echo "Neue Admin-Netze aktiv: $new"
    echo "Automatischer Rollback in ${ROLLBACK_SECONDS}s, falls nicht bestätigt (confirm)."
    ;;
  confirm)
    cancel_timer
    rm -f "$BACKUP"
    echo "Admin-Netze bestätigt."
    ;;
  rollback)
    cancel_timer
    if [[ -f "$BACKUP" ]]; then
      cat "$BACKUP" > "$SETTINGS"
      rm -f "$BACKUP"
      /usr/local/sbin/pangolin-firewall >/dev/null
      echo "Rollback ausgeführt: $(grep '^ADMIN_CIDRS=' "$SETTINGS")"
    else
      echo "Kein Backup vorhanden – nichts zurückzurollen."
    fi
    ;;
  *)
    echo "Verwendung: $0 {show|set|confirm|rollback}" >&2
    exit 2
    ;;
esac
