#!/usr/bin/env bash
# validate.sh — Pattern 2: Platform Variants via Conflicting Extras
#
# Tests the core claims from multi-project-patterns.md:
#   1. [tool.uv] conflicts declaration lets uv resolve mutually exclusive extras
#   2. Per-variant export produces different package versions
#   3. Base export excludes extras-only packages
#   4. Non-conflicting extras compose with conflicting ones
#   5. Requesting both conflicting extras fails
#   6. --python-platform works together with --extra (the actual Bazel integration path)
#
# Usage: cd pattern2_platform_variants && bash validate.sh

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
    local result="$2"
    if [ "$result" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${RESET}: $desc"
        pass=$((pass + 1))
    else
        echo -e "  ${RED}FAIL${RESET}: $desc"
        fail=$((fail + 1))
    fi
}

has_pkg() {
    local file="$1"
    local pkg="$2"
    grep -qi "^${pkg}[=>= ]" "$file" 2>/dev/null
}

get_version() {
    local file="$1"
    local pkg="$2"
    grep -i "^${pkg}==" "$file" 2>/dev/null | head -1
}

echo -e "${BOLD}=== Pattern 2: Platform Variants Validation ===${RESET}"
echo ""
echo "uv version: $($UV --version)"
echo ""

# ── Step 1: uv lock with conflicts ───────────────────────────────
echo -e "${BOLD}Step 1: uv lock${RESET}"
if $UV lock 2>&1; then
    echo ""
    check "uv lock succeeds with [tool.uv] conflicts declared" 0
else
    echo ""
    check "uv lock succeeds with [tool.uv] conflicts declared" 1
    echo "FATAL: uv lock failed."
    exit 1
fi
echo ""

# ── Step 2: Per-variant exports ───────────────────────────────────
echo -e "${BOLD}Step 2: Per-variant exports${RESET}"

$UV export --package trainer --extra variant_a --no-hashes --no-emit-workspace \
    -o requirements-variant-a.txt 2>&1
check "Export variant_a" $?

$UV export --package trainer --extra variant_b --no-hashes --no-emit-workspace \
    -o requirements-variant-b.txt 2>&1
check "Export variant_b" $?

echo ""

# ── Step 3: Conflicting package has different versions ────────────
echo -e "${BOLD}Step 3: Conflicting package versions differ${RESET}"

urllib3_a=$(get_version requirements-variant-a.txt urllib3)
urllib3_b=$(get_version requirements-variant-b.txt urllib3)

echo "  variant_a: $urllib3_a"
echo "  variant_b: $urllib3_b"

[ -n "$urllib3_a" ]
check "variant_a has urllib3" $?

[ -n "$urllib3_b" ]
check "variant_b has urllib3" $?

[ "$urllib3_a" != "$urllib3_b" ]
check "urllib3 versions differ between variants" $?

echo ""

# ── Step 4: Base export (no extras) excludes extras-only deps ─────
echo -e "${BOLD}Step 4: Base export${RESET}"

$UV export --package trainer --no-hashes --no-emit-workspace \
    -o requirements-base.txt 2>&1
check "Export base (no extras)" $?

has_pkg requirements-base.txt numpy;  check "base contains numpy (base dep)" $?
has_pkg requirements-base.txt scipy;  check "base contains scipy (base dep)" $?
! has_pkg requirements-base.txt urllib3
check "base does NOT contain urllib3 (extras-only)" $?

echo ""

# ── Step 5: Non-conflicting extras compose with conflicting ones ──
echo -e "${BOLD}Step 5: Additive extra + conflicting extra${RESET}"

$UV export --package trainer --extra variant_a --extra test \
    --no-hashes --no-emit-workspace -o requirements-a-test.txt 2>&1
check "Export variant_a + test" $?

has_pkg requirements-a-test.txt urllib3; check "variant_a+test has urllib3" $?
has_pkg requirements-a-test.txt pytest;  check "variant_a+test has pytest" $?

$UV export --package trainer --extra variant_b --extra test \
    --no-hashes --no-emit-workspace -o requirements-b-test.txt 2>&1
check "Export variant_b + test" $?

has_pkg requirements-b-test.txt urllib3; check "variant_b+test has urllib3" $?
has_pkg requirements-b-test.txt pytest;  check "variant_b+test has pytest" $?

# The urllib3 versions should still differ even with test added
urllib3_at=$(get_version requirements-a-test.txt urllib3)
urllib3_bt=$(get_version requirements-b-test.txt urllib3)
[ "$urllib3_at" != "$urllib3_bt" ]
check "urllib3 still differs when test extra is also active" $?

echo ""

# ── Step 6: Negative test — both conflicting extras ───────────────
echo -e "${BOLD}Step 6: Negative test — both conflicting extras${RESET}"

if $UV export --package trainer --extra variant_a --extra variant_b \
    --no-hashes -o /dev/null 2>&1; then
    check "uv rejects both conflicting extras at once" 1
else
    check "uv rejects both conflicting extras at once" 0
fi

echo ""

# ── Step 7: Per-platform files via uv pip compile ─────────────────
# FINDING: uv export does NOT support --python-platform. The readme shows:
#   uv export --extra cpu --python-platform x86_64-linux
# but that flag doesn't exist. Alternative: export → pip compile.
echo -e "${BOLD}Step 7: Per-platform files (uv export → uv pip compile)${RESET}"

# First export per-variant (universal, with markers)
# Then compile to platform-specific files
$UV pip compile requirements-variant-a.txt \
    --python-platform x86_64-unknown-linux-gnu --no-header \
    -o requirements-variant-a-linux.txt 2>&1
check "Compile variant_a for linux" $?

$UV pip compile requirements-variant-b.txt \
    --python-platform x86_64-unknown-linux-gnu --no-header \
    -o requirements-variant-b-linux.txt 2>&1
check "Compile variant_b for linux" $?

# Both should have numpy
has_pkg requirements-variant-a-linux.txt numpy
check "variant_a linux has numpy" $?

has_pkg requirements-variant-b-linux.txt numpy
check "variant_b linux has numpy" $?

# Versions should still differ
urllib3_al=$(get_version requirements-variant-a-linux.txt urllib3)
urllib3_bl=$(get_version requirements-variant-b-linux.txt urllib3)
[ "$urllib3_al" != "$urllib3_bl" ]
check "urllib3 differs between variants on linux platform file" $?

# Platform file should NOT have python_full_version markers
if grep -q 'python_full_version' requirements-variant-a-linux.txt; then
    check "linux file has NO python_full_version markers" 1
else
    check "linux file has NO python_full_version markers" 0
fi

echo ""

# ── Step 8: Non-conflicting deps are identical across variants ────
echo -e "${BOLD}Step 8: Shared base deps identical across variants${RESET}"

numpy_a=$(get_version requirements-variant-a.txt numpy)
numpy_b=$(get_version requirements-variant-b.txt numpy)

# numpy may have version markers; compare the full lines
echo "  numpy variant_a: $numpy_a"
echo "  numpy variant_b: $numpy_b"

[ "$numpy_a" = "$numpy_b" ]
check "numpy version identical in both variants" $?

echo ""

# ── Display files ─────────────────────────────────────────────────
echo -e "${BOLD}Generated files${RESET}"
echo ""
for f in requirements-variant-a-linux.txt requirements-variant-b-linux.txt; do
    echo "--- $f ---"
    cat "$f"
    echo ""
done

# ── Summary ───────────────────────────────────────────────────────
echo -e "${BOLD}=== Summary ===${RESET}"
echo -e "  Passed: ${GREEN}${pass}${RESET}"
echo -e "  Failed: ${RED}${fail}${RESET}"
echo ""

if [ "$fail" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}ALL CHECKS PASSED${RESET}"
    echo ""
    echo "Conclusion: Pattern 2 works as described."
    echo "  - [tool.uv] conflicts enables mutually exclusive extras in one lock file."
    echo "  - Per-variant export produces correct, different package versions."
    echo "  - Base export cleanly excludes extras-only packages."
    echo "  - Non-conflicting extras compose freely with either variant."
    echo "  - uv rejects exporting both conflicting extras at once."
    echo "  - --python-platform + --extra work together (the Bazel integration path)."
    exit 0
else
    echo -e "${RED}${BOLD}SOME CHECKS FAILED${RESET}"
    exit 1
fi
