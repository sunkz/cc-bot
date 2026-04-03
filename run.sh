#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CCBot"
SCHEME="$APP_NAME"
BUILD_DIR=".build/DerivedData"
APP_PATH="$BUILD_DIR/Build/Products/Debug/${APP_NAME}.app"

usage() {
    echo "Usage: $0 [generate|build|run|test|clean]"
    echo ""
    echo "Commands:"
    echo "  generate  - Run xcodegen to regenerate the Xcode project"
    echo "  build     - Build the app (runs generate first if .xcodeproj missing)"
    echo "  run       - Build and launch the app"
    echo "  test      - Run unit tests"
    echo "  clean     - Remove build artifacts"
    echo ""
    echo "No arguments defaults to 'run'."
}

cmd_generate() {
    echo "=> Generating Xcode project..."
    xcodegen generate
}

cmd_build() {
    # Auto-generate if xcodeproj is missing
    if [ ! -d "${APP_NAME}.xcodeproj" ]; then
        cmd_generate
    fi

    echo "=> Building ${APP_NAME}..."
    xcodebuild -project "${APP_NAME}.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        build \
        | grep -E '(Build Succeeded|error:|warning:)' || true

    if [ -d "$APP_PATH" ]; then
        echo "=> Build succeeded: $APP_PATH"
    else
        echo "=> Build failed. Run with full output:"
        echo "   xcodebuild -project ${APP_NAME}.xcodeproj -scheme $SCHEME build"
        exit 1
    fi
}

cmd_run() {
    cmd_build

    # Kill existing instance and wait for port to free
    pkill -x "$APP_NAME" 2>/dev/null || true
    for i in $(seq 1 20); do
        lsof -i :62400 &>/dev/null || break
        sleep 0.3
    done

    echo "=> Launching ${APP_NAME}..."
    open "$APP_PATH"
}

cmd_test() {
    if [ ! -d "${APP_NAME}.xcodeproj" ]; then
        cmd_generate
    fi

    echo "=> Running tests..."
    xcodebuild -project "${APP_NAME}.xcodeproj" \
        -scheme "${APP_NAME}Tests" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        test
}

cmd_clean() {
    echo "=> Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    echo "=> Done."
}

# Default to 'run' if no argument
COMMAND="${1:-run}"

case "$COMMAND" in
    generate) cmd_generate ;;
    build)    cmd_build ;;
    run)      cmd_run ;;
    test)     cmd_test ;;
    clean)    cmd_clean ;;
    -h|--help|help) usage ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
