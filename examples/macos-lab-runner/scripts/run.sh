#!/usr/bin/env bash
# Use of this source code is governed by a BSD-style license.
#
# Bundle the headless macOS lab runner and launch it, passing every argument
# through to the binary.
#
# stdout belongs to the runner alone: the device-lab orchestrator greps it for
# JSON event lines and BARNARD_MACHOST_* markers, so build output goes to
# stderr instead.
#
#   ./scripts/run.sh --event-code BND --role auto --timeout 120
#   ./scripts/run.sh --build-only
#   SKIP_BUILD=1 ./scripts/run.sh --role scan --expect-peers 1
#
# Environment: CONFIGURATION, CODESIGN_IDENTITY, BUILD_DIR and APP_DIR are
# passed through to bundle.sh. SKIP_BUILD=1 launches an already-bundled app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_NAME="BarnardLabRunner"
APP_DIR="${APP_DIR:-$EXAMPLE_DIR/build}"
APP_BINARY="$APP_DIR/LabRunner.app/Contents/MacOS/$BINARY_NAME"

BUILD_ONLY=0
args=()
for arg in "$@"; do
  if [ "$arg" = "--build-only" ]; then
    BUILD_ONLY=1
  else
    args+=("$arg")
  fi
done

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  # bundle.sh prints the built binary path on stdout and everything else on
  # stderr, so capturing it here keeps the build silent on our stdout.
  if ! APP_BINARY="$("$SCRIPT_DIR/bundle.sh")"; then
    echo "RESULT=ERROR build failed"
    exit 1
  fi
fi

if [ "$BUILD_ONLY" = "1" ]; then
  echo "[run.sh] built $APP_BINARY" >&2
  exit 0
fi

if [ ! -x "$APP_BINARY" ]; then
  echo "RESULT=ERROR bundled binary not found at $APP_BINARY"
  exit 1
fi

# exec so the orchestrator's backgrounded PID is the runner itself and its
# SIGTERM reaches the engine rather than this wrapper.
echo "[run.sh] launching $APP_BINARY" >&2
exec "$APP_BINARY" ${args[@]+"${args[@]}"}
