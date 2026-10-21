#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Full history is necessary: a shallow checkout gives an incorrect commit count.
[[ "$(git rev-parse --is-shallow-repository)" == false ]] || { echo 'Fetch full Git history first.' >&2; exit 1; }
count="$(git rev-list --count HEAD)"
commit_time="$(git show -s --format=%ct HEAD)"
date_part="$(python3 - "$commit_time" <<'PY'
from datetime import datetime
from zoneinfo import ZoneInfo
import sys
print(datetime.fromtimestamp(int(sys.argv[1]), ZoneInfo('Asia/Singapore')).strftime('%y-%m-%d'))
PY
)"

printf 'RELEASE_TAG=v%s.%03d\n' "$date_part" "$((count % 1000))"
printf 'RELEASE_BUNDLE_VERSION=%s\n' "${date_part//-/.}"
printf 'RELEASE_COMMIT_COUNT=%s\n' "$count"
printf 'RELEASE_PACKAGE_VERSION=%s.%s\n' "${date_part//-/.}" "$count"
