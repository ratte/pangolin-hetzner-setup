#!/usr/bin/env bash
# Installiert alle lokalen Voraussetzungen aus requirements.md (Ubuntu/Debian).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REQ_FILE="$REPO_DIR/requirements.md"

[[ -r /etc/os-release ]] || die "/etc/os-release fehlt – nur Ubuntu/Debian werden unterstützt."
# shellcheck source=/dev/null
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *" debian "*|*" ubuntu "*) ;;
  *) die "Nicht unterstütztes System: ${PRETTY_NAME:-unbekannt} (nur Ubuntu/Debian)." ;;
esac
command -v apt-get >/dev/null || die "apt-get nicht gefunden."

if [[ $EUID -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null || die "sudo fehlt – als root ausführen oder sudo installieren."
  SUDO=(sudo)
fi

mapfile -t packages < <(
  sed -n '/<!-- apt-packages:start -->/,/<!-- apt-packages:end -->/p' "$REQ_FILE" \
    | sed -n 's/^- `\([^`]*\)`.*/\1/p'
)
((${#packages[@]} > 0)) || die "Keine Pakete in $REQ_FILE gefunden."

info "APT-Pakete installieren: ${packages[*]}"
export DEBIAN_FRONTEND=noninteractive
"${SUDO[@]}" apt-get update -qq
"${SUDO[@]}" apt-get install -y -qq "${packages[@]}"
ok "APT-Pakete installiert"

if command -v tofu >/dev/null 2>&1; then
  ok "OpenTofu bereits vorhanden: $(tofu version | head -n1)"
elif command -v terraform >/dev/null 2>&1; then
  ok "Terraform vorhanden (wird statt OpenTofu verwendet): $(terraform version | head -n1)"
else
  info "OpenTofu-Repository einrichten (packages.opentofu.org)"
  "${SUDO[@]}" install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://get.opentofu.org/opentofu.gpg \
    | "${SUDO[@]}" tee /etc/apt/keyrings/opentofu.gpg >/dev/null
  curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey \
    | "${SUDO[@]}" gpg --no-tty --batch --yes --dearmor -o /etc/apt/keyrings/opentofu-repo.gpg
  "${SUDO[@]}" chmod a+r /etc/apt/keyrings/opentofu.gpg /etc/apt/keyrings/opentofu-repo.gpg
  echo "deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/opentofu.list >/dev/null
  "${SUDO[@]}" chmod a+r /etc/apt/sources.list.d/opentofu.list
  "${SUDO[@]}" apt-get update -qq
  "${SUDO[@]}" apt-get install -y -qq tofu
  ok "OpenTofu installiert: $(tofu version | head -n1)"
fi

info "Alle Voraussetzungen erfüllt"
