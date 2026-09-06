#!/usr/bin/env bash
# Use of this source code is governed by a BSD-style license.
#
# Build (unless told to skip) and launch the headless macOS lab runner, passing
# every argument through to the binary.
#
# stdout belongs to the runner alone: the device-lab orchestrator greps it for
# JSON event lines and BARNARD_MACHOST_* markers, so xcodegen and xcodebuild
# output goes to stderr and to a build log instead.
#
#   ./scripts/run.sh --event-code BND --role auto --timeout 120
#   SKIP_BUILD=1 ./scripts/run.sh --role scan --expect-peers 1
#
# Environment:
#   SKIP_BUILD=1        launch the already-built app without rebuilding
#   CONFIGURATION       xcodebuild configuration (default: Debug)
#   CODE_SIGN_IDENTITY  signing identity (default: the project's ad-hoc "-";
#                       set a real identity so the Bluetooth grant survives
#                       rebuilds, see README)
#   BUILD_DIR           derived data path (default: ./build)
#   BUILD_LOG           build transcript (default: $BUILD_DIR/build.log)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_NAME="BarnardLabRunner"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${BUILD_DIR:-$EXAMPLE_DIR/build}"
BUILD_LOG="${BUILD_LOG:-$BUILD_DIR/build.log}"
APP_BINARY="$BUILD_DIR/Build/Products/$CONFIGURATION/$PROJECT_NAME.app/Contents/MacOS/$PROJECT_NAME"

cd "$EXAMPLE_DIR"
mkdir -p "$BUILD_DIR"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "RESULT=ERROR xcodegen not installed (brew install xcodegen)"
    exit 1
  fi

  echo "[run.sh] xcodegen generate" >&2
  xcodegen generate >>"$BUILD_LOG" 2>&1

  echo "[run.sh] xcodebuild build ($CONFIGURATION)" >&2
  xcodebuild_args=(
    -project "$PROJECT_NAME.xcodeproj"
    -scheme "$PROJECT_NAME"
    -configuration "$CONFIGURATION"
    -destination "platform=macOS"
    -derivedDataPath "$BUILD_DIR"
    build
  )
  if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    xcodebuild_args+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY")
  fi
  if ! xcodebuild "${xcodebuild_args[@]}" >>"$BUILD_LOG" 2>&1; then
    echo "[run.sh] build failed, see $BUILD_LOG" >&2
    tail -40 "$BUILD_LOG" >&2 || true
    echo "RESULT=ERROR build failed, see $BUILD_LOG"
    exit 1
  fi
fi

if [ ! -x "$APP_BINARY" ]; then
  echo "RESULT=ERROR built binary not found at $APP_BINARY"
  exit 1
fi

# exec so the orchestrator's backgrounded PID is the runner itself and its
# SIGTERM reaches the engine rather than this wrapper.
echo "[run.sh] launching $APP_BINARY" >&2
exec "$APP_BINARY" "$@"
