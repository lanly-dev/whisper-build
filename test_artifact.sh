#!/usr/bin/env bash
# Test whisper.cpp install tree artifact
# Usage: ./test_artifact.sh [--download] [<artifact.tar.gz>]
#
# Examples:
#   ./test_artifact.sh whisper_install-linux-x86_64.tar.gz       (verify local file)
#   ./test_artifact.sh --download                                  (download latest + verify)

set -euo pipefail

ARTIFACT="${1:-}"

# Handle download mode flag
if [[ $# -gt 0 && "$1" == "--download" ]]; then
    ARTIFACT="__DOWNLOAD_LATEST__"
fi

if [[ -z "$ARTIFACT" ]]; then
    echo "Usage: $0 [--download] [<artifact.tar.gz>]"
    exit 1
fi

# ---------------------------------------------------------------------------
# Download mode: use latest GitHub Release to find artifacts
# Releases are created automatically by the workflow for each build.
# No token needed for public repo releases. For private repos, set GH_TOKEN.
# ---------------------------------------------------------------------------
if [[ "$ARTIFACT" == "__DOWNLOAD_LATEST__" ]]; then
    echo "=== Downloading whisper artifact from latest release ===" 

    # Get latest release tag (no auth needed for public repos)
    if command -v curl &>/dev/null; then
        LATEST_RELEASE=$(curl -sL "https://api.github.com/repos/lanly-dev/whisper-build/releases/latest" \
            -H "Accept: application/vnd.github.v3+json" 2>/dev/null)
        
        if [[ $? -ne 0 || -z "$LATEST_RELEASE" ]]; then
            echo "  [ERROR] Failed to fetch latest release."
            echo "  Set GH_TOKEN for private repos:"
            echo "    export GH_TOKEN='your_token'"
            exit 1
        fi
        
        RELEASE_TAG=$(echo "$LATEST_RELEASE" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
        
        if [[ -z "$RELEASE_TAG" ]]; then
            echo "  [ERROR] Could not determine latest release tag."
            exit 1
        fi
        
        echo "  Latest release: $RELEASE_TAG"
        echo ""
        
        # List available artifacts in this release
        ARTIFACTS=$(echo "$LATEST_RELEASE" | grep -o '"name": *"[^"]*"' | grep 'whisper_install' | cut -d'"' -f4)
        
        if [[ -z "$ARTIFACTS" ]]; then
            echo "  [ERROR] No whisper_install artifacts found in release $RELEASE_TAG."
            exit 1
        fi
        
        echo "  Available artifacts:"
        for art in $ARTIFACTS; do
            echo "    - $art"
        done
        echo ""
        
        # Detect platform and download appropriate artifact
        PLATFORM=""
        case "$(uname -s)" in
            Linux*)   PLATFORM="linux-x86_64" ;;
            Darwin*)  PLATFORM="darwin-universal" ;;
            MINGW*|MSYS*|CYGWIN*) PLATFORM="windows-x86_64" ;;
            *) echo "  [WARN] Unknown platform $(uname -s), downloading linux artifact"; PLATFORM="linux-x86_64" ;;
        esac
        
        ARTIFACT_NAME="whisper_install-${PLATFORM}.tar.gz"
        
        echo "  Downloading $ARTIFACT_NAME to $(pwd) ..."
        curl -sL "https://github.com/lanly-dev/whisper-build/releases/download/${RELEASE_TAG}/${ARTIFACT_NAME}" \
            -o "./$ARTIFACT_NAME"
        
        if [[ $? -ne 0 || ! -f "./$ARTIFACT_NAME" ]]; then
            echo "  [ERROR] Failed to download artifact."
            exit 1
        fi
        
        ARTIFACT="./$ARTIFACT_NAME"
        echo "  Downloaded: $ARTIFACT"
    else
        echo "  curl not found. Install curl or download manually:"
        echo "    https://github.com/lanly-dev/whisper-build/releases/latest"
        exit 1
    fi
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo ""
echo "=== Extracting artifact ==="
tar xzf "$ARTIFACT" -C "$TMPDIR"

echo ""
echo "=== Checking include/ ==="
if ls "$TMPDIR/whisper_target/include/whisper.h" &>/dev/null; then
    echo "  [OK] whisper.h found"
else
    echo "  [FAIL] whisper.h not found!"
    exit 1
fi

echo ""
echo "=== Checking lib/ ==="
if ls "$TMPDIR/whisper_target/lib/"whisper* &>/dev/null; then
    echo "  [OK] Whisper library(s) found:"
    ls -lh "$TMPDIR/whisper_target/lib/"whisper* | awk '{print "      " $NF, "(" $5 ")"}'
else
    echo "  [FAIL] No whisper library found!"
    exit 1
fi

echo ""
echo "=== Checking pkgconfig/ ==="
if ls "$TMPDIR/whisper_target/pkgconfig/"whisper.pc &>/dev/null; then
    echo "  [OK] whisper.pc found"
else
    echo "  [WARN] whisper.pc not found (optional)"
fi

echo ""
echo "=== Building test consumer ==="
mkdir -p "$TMPDIR/test-consumer"
cd "$TMPDIR/test-consumer"

cat > CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.16)
project(test_whisper C)
find_path(WHISPER_INCLUDE_DIR whisper.h PATHS "../whisper_target/include")
find_library(WHISPER_LIB whisper PATHS "../whisper_target/lib")
add_executable(main main.c)
target_include_directories(main PRIVATE ${WHISPER_INCLUDE_DIR})
target_link_libraries(main ${WHISPER_LIB})
EOF

cat > main.c << 'EOF'
#include <whisper.h>
#include <stdio.h>

int main(void) {
    whisper_context *ctx = NULL;
    const char *version = whisper_print_system_info();
    printf("whisper.cpp built on: %s\n", version);
    return 0;
}
EOF

echo "  Configuring..."
cmake -B build \
    -DCMAKE_PREFIX_PATH="$TMPDIR/whisper_target" 2>&1 || {
        echo "  [WARN] CMake find_path/lib failed, falling back to direct paths"
        cmake -B build <<'CMEOF'
cmake_minimum_required(VERSION 3.16)
project(test_whisper C)
add_executable(main main.c)
target_include_directories(main PRIVATE ../whisper_target/include)
target_link_libraries(main ../whisper_target/lib/libwhisper.a)
target_compile_definitions(main PRIVATE WHISPER_NO_CCACHE)
CMEOF
    }

echo "  Building..."
cmake --build build 2>&1 && echo "  [OK] Consumer built successfully!"

echo ""
echo "=== All checks passed ==="