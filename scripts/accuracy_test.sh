#!/bin/bash
# Solves the synthetic test clip with the CLI and checks the camera against ground truth.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swift build
BIN="$(swift build --show-bin-path)/GlassTrack"
"$BIN" --cli tests/data/synthetic_dolly.mp4 "$OUT" balanced 2
PROJECT="$(ls -d "$OUT"/synthetic_dolly_*)"
python3 tests/accuracy_test.py "$PROJECT" tests/data/synthetic_dolly_truth.json
