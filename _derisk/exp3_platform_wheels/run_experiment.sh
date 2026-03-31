#!/usr/bin/env bash
# Experiment 3: Does uv pip install --no-index skip wrong-platform wheels?
#
# Uses pip3 download (which supports --platform) to get cross-platform wheels,
# then tests uv pip install --no-index behavior.

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

UV=uv
PYTHON=python3.11

echo "=== Experiment 3: Platform-Specific Wheel Selection ==="
echo ""

# --- Setup: Download cross-platform wheels using pip ---
echo "--- Setup: Downloading test wheels via pip3 ---"
rm -rf wheels_mixed/ wheels_wrong/ test_venv/ test_venv_b/ test_venv_c/
mkdir -p wheels_mixed wheels_wrong

# Download numpy for macOS ARM
echo "  Downloading numpy for macOS ARM (current platform)..."
pip3 download numpy==1.26.4 \
    --only-binary=:all: \
    --python-version 3.11 \
    --platform macosx_14_0_arm64 \
    --no-deps \
    -d wheels_mixed 2>&1 | tail -3 | sed 's/^/    /'

# Download numpy for Linux x86_64
echo "  Downloading numpy for Linux x86_64..."
pip3 download numpy==1.26.4 \
    --only-binary=:all: \
    --python-version 3.11 \
    --platform manylinux2014_x86_64 \
    --no-deps \
    -d wheels_mixed 2>&1 | tail -3 | sed 's/^/    /'

# Also download a pure python package (should work on any platform)
echo "  Downloading iniconfig (pure python)..."
pip3 download iniconfig==2.0.0 \
    --only-binary=:all: \
    --no-deps \
    -d wheels_mixed 2>&1 | tail -3 | sed 's/^/    /'

echo ""
echo "  Wheels in mixed directory:"
ls -1 wheels_mixed/ | sed 's/^/    /'
echo ""

# --- Test A: Install from mixed-platform directory ---
echo "--- Test A: uv pip install --no-index from mixed-platform directory ---"
$UV venv test_venv --python $PYTHON --quiet 2>&1

echo "  Attempting: uv pip install numpy iniconfig from mixed directory..."
if $UV pip install --python test_venv/bin/python3 --no-deps --no-index \
    --find-links wheels_mixed/ \
    numpy iniconfig 2>&1; then
    echo "  RESULT: Installation succeeded"

    # Verify the right platform was selected
    test_venv/bin/python3 -c "
import numpy
import platform
print(f'    numpy loaded from: {numpy.__file__}')
print(f'    numpy version: {numpy.__version__}')
print(f'    machine: {platform.machine()}')
print(f'    system: {platform.system()}')
# Verify it actually works (would segfault if wrong platform)
import numpy as np
arr = np.array([1, 2, 3])
print(f'    numpy functional: {arr.sum() == 6}')
" 2>&1
    echo "  PASS: uv correctly selected the right-platform wheel"
else
    echo "  RESULT: Installation failed"
    echo "  NOTE: uv may not support --find-links. Trying --index-url with file://..."
fi
echo ""

# --- Test B: Only wrong-platform wheels ---
echo "--- Test B: Only Linux wheels available on macOS ---"
# Copy only linux wheels
for f in wheels_mixed/*linux*; do
    [ -f "$f" ] && cp "$f" wheels_wrong/
done

echo "  Wheels in wrong-platform directory:"
ls -1 wheels_wrong/ 2>/dev/null | sed 's/^/    /'

if [ "$(ls wheels_wrong/ 2>/dev/null | wc -l)" -gt 0 ]; then
    $UV venv test_venv_b --python $PYTHON --quiet 2>&1

    echo "  Attempting install of linux-only wheel on macOS..."
    set +e
    $UV pip install --python test_venv_b/bin/python3 --no-deps --no-index \
        --find-links wheels_wrong/ \
        numpy 2>&1 | sed 's/^/    /'
    exit_code=$?
    set -e

    if [ $exit_code -ne 0 ]; then
        echo "  EXPECTED: uv correctly rejects wrong-platform wheels"
    else
        echo "  UNEXPECTED: uv installed wrong-platform wheel?"
        test_venv_b/bin/python3 -c "import numpy; print(numpy.__file__)" 2>&1 | sed 's/^/    /'
    fi
else
    echo "  SKIP: No linux-specific wheels found"
fi
echo ""

# --- Test C: Direct wheel file installation (bypassing resolution) ---
echo "--- Test C: Direct .whl file path (no --find-links) ---"
$UV venv test_venv_c --python $PYTHON --quiet 2>&1

# Try installing the macOS wheel directly by path
macos_whl=$(ls wheels_mixed/*macos* 2>/dev/null | head -1 || true)
linux_whl=$(ls wheels_mixed/*linux* 2>/dev/null | head -1 || true)

if [ -n "$macos_whl" ]; then
    echo "  Installing macOS wheel directly: $(basename "$macos_whl")"
    if $UV pip install --python test_venv_c/bin/python3 --no-deps "$macos_whl" 2>&1; then
        echo "  PASS: Direct macOS wheel install works"
    else
        echo "  FAIL: Direct macOS wheel install failed"
    fi
fi

if [ -n "$linux_whl" ]; then
    echo "  Installing Linux wheel directly: $(basename "$linux_whl")"
    set +e
    $UV pip install --python test_venv_c/bin/python3 --no-deps "$linux_whl" 2>&1 | sed 's/^/    /'
    exit_code=$?
    set -e
    if [ $exit_code -ne 0 ]; then
        echo "  EXPECTED: Direct install of wrong-platform wheel rejected"
        echo "  KEY INSIGHT: uv checks platform even for direct .whl installs"
    else
        echo "  WARNING: uv installed wrong-platform wheel by direct path!"
        echo "  KEY INSIGHT: install_venv.py MUST filter wheels by platform"
    fi
fi
echo ""

# --- Summary ---
echo "--- Summary ---"
echo "  Key question: Does uv handle platform filtering automatically?"
echo "  If yes -> install_venv.py can pass all wheels blindly"
echo "  If no  -> Starlark rule must filter via select() before passing to action"
echo ""

echo "=== Experiment 3 Complete ==="
