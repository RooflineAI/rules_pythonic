#!/usr/bin/env bash
# validate.sh — Pattern 2b: Additive Extras validation script
#
# This script validates that uv extras are purely additive:
#   - Base export produces only base deps (numpy, scipy)
#   - --extra gpu adds GPU packages without removing base deps
#   - --extra test adds test packages without removing base deps
#   - Multiple extras can be combined
#   - --all-extras is the superset
#   - No [tool.uv] conflicts declaration is needed
#
# Usage: cd pattern2b_additive_extras && bash validate.sh

set -euo pipefail

UV="${UV:-/opt/homebrew/bin/uv}"
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

pass=0
fail=0

check() {
    local desc="$1"
    local result="$2"  # 0 = pass, nonzero = fail
    if [ "$result" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${RESET}: $desc"
        pass=$((pass + 1))
    else
        echo -e "  ${RED}FAIL${RESET}: $desc"
        fail=$((fail + 1))
    fi
}

echo -e "${BOLD}=== Pattern 2b: Additive Extras Validation ===${RESET}"
echo ""

# ── Step 1: uv lock (no conflicts needed) ──────────────────────────
echo -e "${BOLD}Step 1: uv lock${RESET}"
if $UV lock 2>&1; then
    echo ""
    check "uv lock succeeds without [tool.uv] conflicts" 0
else
    echo ""
    check "uv lock succeeds without [tool.uv] conflicts" 1
    echo "FATAL: uv lock failed. Cannot proceed."
    exit 1
fi

# Verify no conflicts section exists in pyproject.toml
if grep -q 'conflicts' pyproject.toml; then
    check "No conflicts declaration in root pyproject.toml" 1
else
    check "No conflicts declaration in root pyproject.toml" 0
fi

echo ""

# ── Step 2: Export various combinations ─────────────────────────────
echo -e "${BOLD}Step 2: Export requirements files${RESET}"

$UV export --package trainer --no-hashes -o requirements-base.txt 2>&1
check "Export base requirements" $?

$UV export --package trainer --extra gpu --no-hashes -o requirements-gpu.txt 2>&1
check "Export gpu requirements" $?

$UV export --package trainer --extra test --no-hashes -o requirements-test.txt 2>&1
check "Export test requirements" $?

$UV export --package trainer --extra gpu --extra test --no-hashes -o requirements-gpu-test.txt 2>&1
check "Export gpu+test requirements" $?

$UV export --package trainer --all-extras --no-hashes -o requirements-all.txt 2>&1
check "Export all-extras requirements" $?

echo ""

# ── Step 3: Verify contents ─────────────────────────────────────────
echo -e "${BOLD}Step 3: Verify requirements file contents${RESET}"
echo ""

echo "--- requirements-base.txt ---"
cat requirements-base.txt
echo ""

echo "--- requirements-gpu.txt ---"
cat requirements-gpu.txt
echo ""

echo "--- requirements-test.txt ---"
cat requirements-test.txt
echo ""

echo "--- requirements-gpu-test.txt ---"
cat requirements-gpu-test.txt
echo ""

echo "--- requirements-all.txt ---"
cat requirements-all.txt
echo ""

# ── Step 4: Validate base has numpy and scipy ───────────────────────
echo -e "${BOLD}Step 4: Content validation${RESET}"

# Helper: check if a package appears in a requirements file (case-insensitive)
has_pkg() {
    local file="$1"
    local pkg="$2"
    # Match package name at start of line, allow - or _ normalization
    grep -qi "^${pkg}[==> ]" "$file" 2>/dev/null
}

# 4a: Base should have numpy, scipy; should NOT have cupy, pytest, hypothesis, ruff, mypy
has_pkg requirements-base.txt numpy;      check "base contains numpy" $?
has_pkg requirements-base.txt scipy;      check "base contains scipy" $?
! has_pkg requirements-base.txt cupy;     check "base does NOT contain cupy" $?
! has_pkg requirements-base.txt pytest;   check "base does NOT contain pytest" $?
! has_pkg requirements-base.txt hypothesis; check "base does NOT contain hypothesis" $?
! has_pkg requirements-base.txt ruff;     check "base does NOT contain ruff" $?
! has_pkg requirements-base.txt mypy;     check "base does NOT contain mypy" $?

echo ""

# 4b: GPU should have numpy, scipy, cupy; should NOT have pytest
has_pkg requirements-gpu.txt numpy;       check "gpu contains numpy" $?
has_pkg requirements-gpu.txt scipy;       check "gpu contains scipy" $?
has_pkg requirements-gpu.txt cupy-cuda12x; check "gpu contains cupy-cuda12x" $?
! has_pkg requirements-gpu.txt pytest;    check "gpu does NOT contain pytest" $?

echo ""

# 4c: Test should have numpy, scipy, pytest, hypothesis; should NOT have cupy
has_pkg requirements-test.txt numpy;      check "test contains numpy" $?
has_pkg requirements-test.txt scipy;      check "test contains scipy" $?
has_pkg requirements-test.txt pytest;     check "test contains pytest" $?
has_pkg requirements-test.txt hypothesis; check "test contains hypothesis" $?
! has_pkg requirements-test.txt cupy;     check "test does NOT contain cupy" $?

echo ""

# 4d: GPU+Test should have all of numpy, scipy, cupy, pytest, hypothesis
has_pkg requirements-gpu-test.txt numpy;      check "gpu+test contains numpy" $?
has_pkg requirements-gpu-test.txt scipy;      check "gpu+test contains scipy" $?
has_pkg requirements-gpu-test.txt cupy-cuda12x; check "gpu+test contains cupy-cuda12x" $?
has_pkg requirements-gpu-test.txt pytest;     check "gpu+test contains pytest" $?
has_pkg requirements-gpu-test.txt hypothesis; check "gpu+test contains hypothesis" $?

echo ""

# 4e: All-extras should be superset (numpy, scipy, cupy, pytest, hypothesis, ruff, mypy)
has_pkg requirements-all.txt numpy;      check "all contains numpy" $?
has_pkg requirements-all.txt scipy;      check "all contains scipy" $?
has_pkg requirements-all.txt cupy-cuda12x; check "all contains cupy-cuda12x" $?
has_pkg requirements-all.txt pytest;     check "all contains pytest" $?
has_pkg requirements-all.txt hypothesis; check "all contains hypothesis" $?
has_pkg requirements-all.txt ruff;       check "all contains ruff" $?
has_pkg requirements-all.txt mypy;       check "all contains mypy" $?

echo ""

# ── Step 5: Verify version consistency across exports ───────────────
echo -e "${BOLD}Step 5: Version consistency (base packages same across all exports)${RESET}"

get_version() {
    local file="$1"
    local pkg="$2"
    grep -i "^${pkg}==" "$file" 2>/dev/null | head -1
}

numpy_base=$(get_version requirements-base.txt numpy)
numpy_gpu=$(get_version requirements-gpu.txt numpy)
numpy_test=$(get_version requirements-test.txt numpy)
numpy_all=$(get_version requirements-all.txt numpy)

scipy_base=$(get_version requirements-base.txt scipy)
scipy_gpu=$(get_version requirements-gpu.txt scipy)
scipy_test=$(get_version requirements-test.txt scipy)
scipy_all=$(get_version requirements-all.txt scipy)

echo "  numpy versions: base=$numpy_base | gpu=$numpy_gpu | test=$numpy_test | all=$numpy_all"
echo "  scipy versions: base=$scipy_base | gpu=$scipy_gpu | test=$scipy_test | all=$scipy_all"

[ "$numpy_base" = "$numpy_gpu" ] && [ "$numpy_base" = "$numpy_test" ] && [ "$numpy_base" = "$numpy_all" ]
check "numpy version identical across all exports" $?

[ "$scipy_base" = "$scipy_gpu" ] && [ "$scipy_base" = "$scipy_test" ] && [ "$scipy_base" = "$scipy_all" ]
check "scipy version identical across all exports" $?

echo ""

# ── Summary ─────────────────────────────────────────────────────────
echo -e "${BOLD}=== Summary ===${RESET}"
echo -e "  Passed: ${GREEN}${pass}${RESET}"
echo -e "  Failed: ${RED}${fail}${RESET}"
echo ""

if [ "$fail" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}ALL CHECKS PASSED${RESET}"
    echo ""
    echo "Conclusion: Additive extras work correctly with uv."
    echo "  - No [tool.uv] conflicts declaration is needed for purely additive extras."
    echo "  - 'uv export' without extras gives base deps only."
    echo "  - '--extra <name>' adds packages on top of base deps."
    echo "  - Multiple '--extra' flags can be combined freely."
    echo "  - '--all-extras' produces the full superset."
    echo "  - Base package versions are identical across all export variants."
    exit 0
else
    echo -e "${RED}${BOLD}SOME CHECKS FAILED${RESET}"
    exit 1
fi
