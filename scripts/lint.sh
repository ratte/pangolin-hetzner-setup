#!/usr/bin/env bash
# Static checks of the repository (no Hetzner access needed):
# Bash syntax, shellcheck (if installed), OpenTofu fmt/validate.
set -uo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rc=0

info "Bash syntax"
while IFS= read -r f; do
  if bash -n "$f"; then ok "$f"; else rc=1; fi
done < <(find "$REPO_DIR" -name '*.sh' -not -path '*/.terraform/*' | sort)

if command -v shellcheck >/dev/null 2>&1; then
  info "shellcheck"
  find "$REPO_DIR" -name '*.sh' -not -path '*/.terraform/*' -print0 \
    | xargs -0 shellcheck -x -S warning && ok "shellcheck clean" || rc=1
else
  warn "shellcheck not installed – skipped (apt install shellcheck)"
fi

if command -v tofu >/dev/null 2>&1 || command -v terraform >/dev/null 2>&1; then
  info "OpenTofu fmt/validate"
  tf fmt -check -recursive && ok "Formatting" || { warn "run tofu fmt -recursive terraform/"; rc=1; }
  tf init -backend=false -input=false >/dev/null && tf validate && ok "validate" || rc=1
else
  warn "OpenTofu not installed – skipped"
fi

exit "$rc"
