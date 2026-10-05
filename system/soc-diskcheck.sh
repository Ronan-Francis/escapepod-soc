#!/bin/sh
# Log root filesystem usage as one logfmt line, e.g. "root_used_pct=5 avail_gb=426.1".
# Runs from soc-diskcheck.timer; the journal -> Alloy -> Loki pipeline does the
# rest, so no metrics database is needed for a single number.
set -eu
df -P -B1 / | awk 'NR == 2 { printf "root_used_pct=%d avail_gb=%.1f\n", $5 + 0, $4 / 1073741824 }'
