#!/usr/bin/env bash
# Fail if banned chrome strings reappear outside allowlists.
# Canonical names live in docs/glossary.md and Shared/HeadroomCopy.swift.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail=0

search() {
  local pattern="$1"
  shift
  if command -v rg >/dev/null 2>&1; then
    rg -n --glob '!docs/glossary.md' --glob '!scripts/check-glossary-copy.sh' \
      --glob '!**/HeadroomCopy.swift' --glob '!**/test_*.py' \
      -e "$pattern" "$@" 2>/dev/null || true
  else
    grep -Rn --exclude=glossary.md --exclude=check-glossary-copy.sh \
      --exclude=HeadroomCopy.swift --exclude='test_*.py' \
      -E "$pattern" "$@" 2>/dev/null || true
  fi
}

check_absent() {
  local pattern="$1"
  local hint="$2"
  local hits
  # `host` is in here because the host writes copy, not just data: `headline`
  # and `verdict` are prose the clients cannot retitle, and `verdict` is the
  # only string the ESP32 draws. Leaving Python out of the search path meant
  # the most-read sentence in the product was the one nothing checked.
  # The two ESP32 renderers are in here because they hold a third copy of the
  # firmware's chrome strings (docs/esp32.md) — a banned phrase revived there
  # ships in every preview and screenshot.
  hits="$(search "$pattern" macos/Sources ios/HeadroomMobile widget watch Shared firmware/src host \
    scripts/render_esp32_preview.py scripts/render_esp32_boot.py)"
  if [[ -n "$hits" ]]; then
    echo "Banned phrase found ($hint):"
    echo "$hits"
    fail=1
  fi
}

# Same idea, scoped to named files: a pattern that is fine elsewhere in the
# app but must never appear in these.
check_absent_in() {
  local pattern="$1"
  local hint="$2"
  shift 2
  local hits
  hits="$(search "$pattern" "$@")"
  if [[ -n "$hits" ]]; then
    echo "Banned style found ($hint):"
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

# A burndown says which of the two frames it draws, and the words come from
# `frameLabel` on the domain — never typed into a view. A surface that hardcodes
# one is a surface that keeps saying "This window" after the domain has been
# clipped to a seven-day slice inside it. See docs/glossary.md, "Charts".
check_absent 'Text\("(This window|7 days( around today| of this window)?)"\)' \
  'use Domain.frameLabel — the domain knows which frame it drew'
check_absent '"collecting history"' 'use Collecting history / LABEL_COLLECTING_HISTORY'

# Percent is the only unit Headroom claims. Claude bills in points, Cursor in
# requests, GitHub in premium requests — a figure this app labels "pts" reads
# as one of theirs. `pts` stays legal as a JSON key (device_view, firmware);
# these are the phrasings that reach a reader.
check_absent 'pts / day' 'use HeadroomCopy.dailyBurnUnit ("% / day")'
check_absent 'pts back' 'reset grants are a share of the window: "N% back"'
check_absent '_points\(' 'use burndown._spare — signed, and in percent'

# One axis, one noun. The headline and the verdict say "On pace" / "Over pace"
# for the same two states; "On track" was a third word for the first of them.
check_absent '"On track' 'use "On pace" — pairs with "Over pace"'

# "Unavailable" was carrying a missing key, a failed fetch, a dead host, and a
# provider that just didn't name the plan. Each of those wants a different
# sentence, and three of them are actionable.
check_absent '(Supabase|Plausible|PostHog|Advisors) unavailable' \
  'use HeadroomCopy.serviceStatus / serviceNotReporting'
check_absent 'Plan unavailable' 'use HeadroomCopy.planUnknown'
check_absent 'backend unavailable' 'the user-facing name is the host'

# Headroom speaks in the second person. See docs/glossary.md, "Voice".
check_absent 'Text\("(We|Our|I) ' 'no first person in UI copy — say "you" or name the thing'

# Quota meters and burndown never alarm. Running out is a reading the words
# already deliver; red says it a second time, louder. Only exhaustion shifts
# the colour, and it recedes (`tint.drained()`) rather than warns. Dropped
# once in fd29592 and reintroduced by a later refactor — hence this guard.
# Attention cards and source health dots keep their green/orange/red.
check_absent_in '(Color\.red|Color\.orange|: \.red\b|: \.orange\b|\(\.red\)|\(\.orange\))' \
  'burndown/quota views never alarm — see docs/glossary.md "Colour"' \
  macos/Sources/BurndownCard.swift \
  macos/Sources/QuotaSection.swift \
  macos/Sources/DailyBurnCard.swift

# The banned-phrase checks above cannot notice one side of a mirror renaming —
# they only see reintroductions. The firmware LABEL_* constants that have a
# HeadroomCopy counterpart are compared by value, so `LABEL_BURNDOWN = "Burn
# down"` fails here instead of shipping a board that disagrees with the apps.
fw_label() {
  sed -n "s/^static const char \*$1 = \"\(.*\)\";.*/\1/p" firmware/src/main.cpp | head -1
}
copy_const() {
  sed -n "s/^ *static let $1 = \"\(.*\)\"\$/\1/p" Shared/HeadroomCopy.swift | head -1
}
check_label() {
  local label="$1" swift_name="$2" fw sw
  fw="$(fw_label "$label")"
  sw="$(copy_const "$swift_name")"
  if [[ -z "$fw" || -z "$sw" || "$fw" != "$sw" ]]; then
    echo "Label drift: firmware $label='${fw:-missing}' vs HeadroomCopy.$swift_name='${sw:-missing}'"
    fail=1
  fi
}

check_label LABEL_BURNDOWN burndown
check_label LABEL_DAILY_BURN dailyBurn
check_label LABEL_SPEND spend
check_label LABEL_COLLECTING_HISTORY collectingHistory

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "See docs/glossary.md for canonical names."
  exit 1
fi

echo "glossary copy check ok"
