#!/usr/bin/env bash
# Fail if banned chrome strings reappear outside allowlists.
# Canonical names live in docs/glossary.md and Shared/HeadroomCopy.swift.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail=0

search() {
  local pattern="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -n --glob '!docs/glossary.md' --glob '!scripts/check-glossary-copy.sh' \
      --glob '!**/HeadroomCopy.swift' \
      -e "$pattern" "$@" 2>/dev/null || true
  else
    grep -Rn --exclude=glossary.md --exclude=check-glossary-copy.sh \
      --exclude=HeadroomCopy.swift \
      -E "$pattern" "$@" 2>/dev/null || true
  fi
}

check_absent() {
  local pattern="$1"
  local hint="$2"
  local hits
  hits="$(search "$pattern" macos/Sources ios/HeadroomMobile ios/HeadroomWidget Shared firmware/src)"
  if [[ -n "$hits" ]]; then
    echo "Banned phrase found ($hint):"
    echo "$hits"
    fail=1
  fi
}

check_absent 'All quota burn' 'use HeadroomCopy.dailyBurn'
check_absent 'All systems clear' 'use HeadroomCopy.allClear or connected'
check_absent 'Nothing needs attention' 'use HeadroomCopy.allClear'
check_absent 'Clear everywhere' 'use HeadroomCopy.clearAttention'
check_absent 'History will appear after' 'use HeadroomCopy.noHistoryYet'
check_absent 'Burn history starts after' 'use HeadroomCopy.noBurnHistoryYet'
check_absent 'Enable a coding provider' 'use HeadroomCopy.noCodingSources'
check_absent 'Quota points / day' 'use HeadroomCopy.dailyBurnUnit'
check_absent 'DataSection\(title: "GitHub"\)' 'use HeadroomCopy.activity'
check_absent 'Text\("Daily burn"\)' 'use HeadroomCopy.dailyBurn'
check_absent 'Text\("Overall burndown"\)' 'use HeadroomCopy.overallBurndown'
check_absent 'Text\("Coding quotas"\)' 'use HeadroomCopy.codingQuotas'
check_absent 'Text\("Burndown"\)' 'use HeadroomCopy.burndown / LABEL_BURNDOWN'
check_absent '"collecting history"' 'use Collecting history / LABEL_COLLECTING_HISTORY'

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "See docs/glossary.md for canonical names."
  exit 1
fi

echo "glossary copy check ok"
