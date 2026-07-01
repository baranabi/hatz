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
    "$ZIG" build test -- --color off 2>&1
    echo ""
    echo "Coverage skipped (no kcov). To install:"
    echo "  Linux: sudo apt install kcov  (or build from source)"
    echo "  macOS: brew install kcov"
    echo ""
    exit 0
fi

echo "kcov version: $KCOV_VERSION"

# Quick test: verify kcov can trace processes (ptrace on Linux, task_for_pid on macOS)
kcov_ok=0
test_dir=$(mktemp -d)
if kcov --clean "$test_dir" /bin/true >/dev/null 2>&1; then
    kcov_ok=1
fi
rm -rf "$test_dir"

if [ "$kcov_ok" -eq 0 ]; then
    echo ""
    echo "WARNING: kcov cannot trace processes on this system."
    echo ""
    echo "On macOS, kcov needs code signing or root for ptrace access:"
    echo "  1) Sign with Apple Developer ID (recommended):"
    echo "     codesign -s 'Developer ID Application:...' \\"
    echo "       --entitlements osx-entitlements.xml -f \$(which kcov)"
    echo ""
    echo "  2) Or run this script as root:"
    echo "     sudo bash tools/coverage.sh"
    echo ""
    echo "  3) Or run on Linux (CI, Docker):"
    echo "     docker run --rm -v \$PWD:/src alpine/kcov ..."
    echo ""
    echo "Falling back: running tests and collecting coverage via llvm-cov"
    echo "(less detailed: no per-line hit counts, source listing only)"
    echo ""

    # Fallback: produce a source listing with debug info
    echo "Building test executables..."
    "$ZIG" build test -- --color off 2>&1

    # Find test binary
    TEST_BIN=$(find .zig-cache -name "test" -type f -perm +111 2>/dev/null \
        | sort -t'/' -k7 -r | head -1)

    if [ -z "$TEST_BIN" ]; then
        echo "ERROR: no test binary found." >&2
        exit 1
    fi

    echo "Test binary at: $TEST_BIN"
    echo ""
    echo "Coverage is not available on this macOS setup without signing kcov."
    echo "To set up proper coverage, see instructions above."
    echo ""
    echo "Source files for reference:"
    echo "  src/engine/"
    exit 0
fi

# Clean previous coverage
rm -rf coverage/

# Build test executables
echo "Building test executables..."
"$ZIG" build test -- --color off 2>&1 || {
    echo "ERROR: zig build test failed" >&2
    exit 1
}

# Find test binaries (two: mod_tests + exe_tests)
echo "Finding test binaries..."
TEST_BINS=$(find .zig-cache -name "test" -type f -perm +111 2>/dev/null \
    | sort -t'/' -k7 -r | head -2 || true)

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
