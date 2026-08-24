#!/usr/bin/env bash
# Smoke test for gdtime CLI history batch — runs from repo root via test/cli manifests
# Usage: ./test/cli/run_cli_smoke.sh [--keep]  (--keep leaves worktrees on failure)
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
GDTIME="./addons/GdTimeMachine/cli/gdtime"
if [[ ! -x "$GDTIME" ]]; then
  GDTIME="addons/GdTimeMachine/cli/gdtime"
fi

KEEP=""
if [[ "$1" == "--keep" ]]; then
  KEEP="--keep-failed"
fi

echo "=== gdtime validate ==="
"$GDTIME" validate test/cli/manifest_single.json
"$GDTIME" validate test/cli/manifest_history.json
echo "✔ validate ok"

echo "=== gdtime run --dry-run ==="
"$GDTIME" run --dry-run test/cli/manifest_single.json
"$GDTIME" run --dry-run test/cli/manifest_history.json
echo "✔ dry-run ok"

echo "=== gdtime run (history batch, 2 entries, 2s each) ==="
# Ensure output dir exists and is clean for this run
rm -rf media/captures/history_smoke/history-head.avi media/captures/history_smoke/history-ab07fa8.avi 2>/dev/null || true
mkdir -p media/captures/history_smoke
if [[ -n "$KEEP" ]]; then
  "$GDTIME" run $KEEP test/cli/manifest_history.json
else
  "$GDTIME" run test/cli/manifest_history.json
fi
echo "✔ run ok"

echo "=== check output ==="
ls -lh media/captures/history_smoke/history-head.avi media/captures/history_smoke/history-ab07fa8.avi
# Basic sanity: files should be >100K and 60 frames @ 30 FPS is ~2.0M in manual test, but at least >0
for f in media/captures/history_smoke/history-head.avi media/captures/history_smoke/history-ab07fa8.avi; do
  if [[ ! -f "$f" ]]; then
    echo "✘ missing $f" >&2
    exit 1
  fi
  size=$(stat -c%s "$f")
  if [[ "$size" -lt 100000 ]]; then
    echo "✘ $f too small ($size bytes, expected >100K)" >&2
    exit 1
  fi
  echo "✔ $f exists ($size bytes)"
done

echo "=== worktree cleanup ==="
if git worktree list 2>&1 | grep -q ".worktrees/history-"; then
  echo "✘ orphan worktrees remain:" >&2
  git worktree list | grep ".worktrees/history-"
  exit 1
fi
echo "✔ no orphan worktrees"

echo "=== smoke passed ==="
