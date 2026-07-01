#!/usr/bin/env bash
# hatz code coverage tool
# Uses kcov (Linux: works out of the box; macOS: needs codesign or sudo)
set -uo pipefail

HATZ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HATZ_DIR"

# Determine zig binary
ZIG="${ZIG:-$(which zig 2>/dev/null || echo "$HOME/bin/zig")}"
if [ ! -x "$ZIG" ]; then
    echo "ERROR: zig not found. Set ZIG env var or install zig." >&2
    exit 1
fi

# Install kcov if missing
if ! command -v kcov &>/dev/null; then
    echo "Installing kcov via brew..."
    brew install kcov
fi

# Check kcov availability
KCOV_VERSION=""
if command -v kcov &>/dev/null; then
    KCOV_VERSION=$(kcov --version 2>&1 | head -1) || true
fi

if [ -z "$KCOV_VERSION" ]; then
    echo ""
    echo "kcov not available — skipping code coverage."
    echo ""
    echo "Building test executables..."
    "$ZIG" build test 2>&1
    echo ""
    echo "Coverage skipped (no kcov). To install:"
    echo "  Linux: sudo apt install kcov  (or build from source)"
    echo "  macOS: brew install kcov"
    echo ""
    exit 0
fi

echo "kcov version: $KCOV_VERSION"
echo ""

# Clean previous coverage
rm -rf coverage/

# Build test executables
echo "Building test executables..."
BUILD_MARKER=$(mktemp /tmp/hatz-build-start.XXXXXX)
"$ZIG" build test 2>&1 || {
    echo "ERROR: zig build test failed" >&2
    exit 1
}

# Find test binaries built just now (newer than marker)
echo "Finding test binaries..."
TEST_BINS=$(find .zig-cache -name "test" -type f -perm -111 -newer "$BUILD_MARKER" 2>/dev/null | sort -u || true)
rm -f "$BUILD_MARKER"

if [ -z "$TEST_BINS" ]; then
    echo "ERROR: no test binaries found. Did zig build test succeed?" >&2
    exit 1
fi

echo "Found $(echo "$TEST_BINS" | wc -l | tr -d ' ') test binary(ies)."

# Run kcov on each test binary (merges into same coverage/ dir)
for bin in $TEST_BINS; do
    echo "  kcov: $(basename "$(dirname "$bin")")..."
    kcov \
        --include-pattern=src/engine \
        --exclude-pattern=zig-cache \
        --skip-solibs \
        coverage/ \
        "$bin" \
        2>&1 | grep -v 'kcov: debug: ' || true
done

# Remove empty test entries from merged index (those with 0 instrumented lines)
MERGED_JS="coverage/index.js"
if [ -f "$MERGED_JS" ]; then
    sed -i '' '/"total_lines"[[:space:]]*:[[:space:]]*"0"/d' "$MERGED_JS" 2>/dev/null || true
    sed -i '' 's/,\s*\]/]/' "$MERGED_JS" 2>/dev/null || true
fi

# Patch kcov.js to handle 0/0 (NaN) when no lines instrumented
KCOV_JS="coverage/data/js/kcov.js"
if [ -f "$KCOV_JS" ]; then
    # Fix header percent calculation
    sed -i '' 's|elem.innerHTML = ((header.covered / header.instrumented) \* 100).toFixed(1) + "%";|if (header.instrumented > 0) {\n\t\telem.className = toCoverPercentString(header.covered, header.instrumented);\n\t\telem.innerHTML = ((header.covered / header.instrumented) * 100).toFixed(1) + "%";\n\t} else {\n\t\telem.className = "coverPerLeftLo";\n\t\telem.innerHTML = "N/A";\n\t}|' "$KCOV_JS" 2>/dev/null || true
    # Fix toCoverPercentString for zero instrumented
    sed -i '' 's|function toCoverPercentString (covered, instrumented) {|function toCoverPercentString (covered, instrumented) {\n\tif (instrumented === 0) return "coverPerLeftLo";|' "$KCOV_JS" 2>/dev/null || true
fi

# Verify output
REPORT="coverage/index.html"
if [ -f "$REPORT" ]; then
    echo ""
    echo "===== Coverage Report ====="
    if command -v python3 &>/dev/null; then
        python3 -c "
import re
with open('coverage/index.html') as f:
    html = f.read()
rows = re.findall(r'<tr[^>]*>.*?</tr>', html, re.DOTALL)
for row in rows:
    cells = re.findall(r'<t[dh][^>]*>(.*?)</t[dh]>', row, re.DOTALL)
    if len(cells) >= 6 and 'src/engine' in row:
        name = cells[0].strip()
        lines = cells[1].strip()
        covered = cells[2].strip()
        missed = cells[3].strip()
        pct = cells[4].strip()
        print(f'  {name:35s}  lines={lines:>5s}  covered={covered:>5s}  missed={missed:>5s}  {pct}')
" 2>/dev/null || true
    fi
    echo ""
    echo "Full HTML report: $(pwd)/$REPORT"
    echo "Open with:   open $REPORT"
    echo "Or:          zig build coverage-html"
else
    echo "WARNING: coverage report not found — kcov may have failed silently."
    echo "Check $(pwd)/coverage/ for any partial output."
fi
