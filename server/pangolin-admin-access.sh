#!/usr/bin/env bash
# pangolin-admin-access – restrict SSH access to specific networks, with an
# automatic rollback if no confirmation arrives.
#
#   pangolin-admin-access show
#   pangolin-admin-access set "203.0.113.10/32 2001:db8::/48"   # or "any"
#   pangolin-admin-access confirm      # keep the new rules
#   pangolin-admin-access rollback     # restore the previous rules
#
# After "set", the change is rolled back automatically after ROLLBACK_SECONDS
# unless "confirm" is called (from a NEW SSH connection).
set -euo pipefail

SETTINGS=/etc/pangolin-setup/settings.env
BACKUP=/etc/pangolin-setup/settings.env.bak
UNIT=pangolin-admin-rollback
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-180}"

[[ $EUID -eq 0 ]] || { echo "Please run with sudo." >&2; exit 1; }

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
    [[ -n "$new" ]] || { echo "Usage: $0 set \"<cidr> [<cidr> ...]|any\"" >&2; exit 2; }
    for c in $new; do
      valid_cidr "$c" || { echo "Invalid network: $c" >&2; exit 2; }
    done
    if [[ " $new " == *" any "* ]] && [[ "$new" != "any" ]]; then
      echo "\"any\" must not be combined with other networks." >&2; exit 2
    fi
    cancel_timer
    # Do not overwrite an existing backup (last confirmed state).
    [[ -f "$BACKUP" ]] || cp -p "$SETTINGS" "$BACKUP"
    tmp="$(mktemp)"
    sed "s|^ADMIN_CIDRS=.*|ADMIN_CIDRS=\"${new}\"|" "$SETTINGS" > "$tmp"
    cat "$tmp" > "$SETTINGS"
    rm -f "$tmp"
    /usr/local/sbin/pangolin-firewall >/dev/null
    systemd-run --quiet --unit="$UNIT" --on-active="${ROLLBACK_SECONDS}" \
      /usr/local/sbin/pangolin-admin-access rollback
    echo "New admin networks active: $new"
    echo "Automatic rollback in ${ROLLBACK_SECONDS}s unless confirmed (confirm)."
    ;;
  confirm)
    cancel_timer
    rm -f "$BACKUP"
    echo "Admin networks confirmed."
    ;;
  rollback)
    cancel_timer
    if [[ -f "$BACKUP" ]]; then
      cat "$BACKUP" > "$SETTINGS"
      rm -f "$BACKUP"
      /usr/local/sbin/pangolin-firewall >/dev/null
      echo "Rollback done: $(grep '^ADMIN_CIDRS=' "$SETTINGS")"
    else
      echo "No backup present – nothing to roll back."
    fi
    ;;
  *)
    echo "Usage: $0 {show|set|confirm|rollback}" >&2
    exit 2
    ;;
esac
