#!/usr/bin/env bash
# Statische Prüfung des Repositorys (ohne Hetzner-Zugang):
# Bash-Syntax, shellcheck (falls installiert), OpenTofu fmt/validate.
set -uo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rc=0

info "Bash-Syntax"
while IFS= read -r f; do
  if bash -n "$f"; then ok "$f"; else rc=1; fi
done < <(find "$REPO_DIR" -name '*.sh' -not -path '*/.terraform/*' | sort)

if command -v shellcheck >/dev/null 2>&1; then
  info "shellcheck"
  find "$REPO_DIR" -name '*.sh' -not -path '*/.terraform/*' -print0 \
    | xargs -0 shellcheck -x -S warning && ok "shellcheck sauber" || rc=1
else
  warn "shellcheck nicht installiert – übersprungen (apt install shellcheck)"
fi

if command -v tofu >/dev/null 2>&1 || command -v terraform >/dev/null 2>&1; then
  info "OpenTofu fmt/validate"
  tf fmt -check -recursive && ok "Formatierung" || { warn "tofu fmt -recursive terraform/ ausführen"; rc=1; }
  tf init -backend=false -input=false >/dev/null && tf validate && ok "validate" || rc=1
else
  warn "OpenTofu nicht installiert – übersprungen"
fi

exit "$rc"
