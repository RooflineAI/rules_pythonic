#!/usr/bin/env bash
# validate.sh — Pattern 5: Combining Platform Variants with Multiple Products
#
# Tests the core claims from multi-project-patterns.md:
#   1. Two separate workspaces, each with independent uv lock
#   2. Main workspace uses [tool.uv] conflicts for mutually exclusive extras (cpu vs cuda12)
#   3. Legacy workspace uses a simple extra (cuda11) — no conflicts needed
#   4. Per-variant export from each workspace produces correct packages
#   5. Two-step export (uv export → uv pip compile --python-platform) works per workspace
#   6. The two workspaces resolve independently (different urllib3 versions)
#
# This is the combination of Pattern 2 (conflicting extras) + Pattern 4 (separate workspaces).
#
# Usage: cd pattern5_combined && bash validate.sh

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
    grep -qi "^${pkg}[=>;, ]" "$file" 2>/dev/null
}

get_version() {
    local file="$1"
    local pkg="$2"
    grep -i "^${pkg}==" "$file" 2>/dev/null | head -1 | sed 's/ *;.*//'
}

echo -e "${BOLD}=== Pattern 5: Combined Variants + Multiple Products ===${RESET}"
echo ""

# ── Step 1: Lock both workspaces independently ───────────────────
echo -e "${BOLD}Step 1: Lock both workspaces${RESET}"

if $UV lock --directory "$DIR/main" 2>&1; then
    echo ""
    check "Main workspace uv lock succeeds (with conflicts)" 0
else
    echo ""
    check "Main workspace uv lock succeeds (with conflicts)" 1
    echo "FATAL: main uv lock failed."
    exit 1
fi

if $UV lock --directory "$DIR/legacy" 2>&1; then
    echo ""
    check "Legacy workspace uv lock succeeds" 0
else
    echo ""
    check "Legacy workspace uv lock succeeds" 1
    echo "FATAL: legacy uv lock failed."
    exit 1
fi
echo ""

# ── Step 2: Main workspace — per-variant exports ─────────────────
echo -e "${BOLD}Step 2: Main workspace exports (cpu vs cuda12)${RESET}"

$UV export --package trainer --extra cpu --no-hashes --no-emit-workspace \
    --directory "$DIR/main" -o "$DIR/main/requirements-cpu.txt" 2>&1
check "Main: export cpu variant" $?

$UV export --package trainer --extra cuda12 --no-hashes --no-emit-workspace \
    --directory "$DIR/main" -o "$DIR/main/requirements-cuda12.txt" 2>&1
check "Main: export cuda12 variant" $?

echo ""

# ── Step 3: Main — verify conflicting extras produce different content ─
echo -e "${BOLD}Step 3: Main workspace variant content${RESET}"

# Both have base deps
has_pkg "$DIR/main/requirements-cpu.txt" numpy;  check "main cpu has numpy" $?
has_pkg "$DIR/main/requirements-cpu.txt" scipy;  check "main cpu has scipy" $?
has_pkg "$DIR/main/requirements-cuda12.txt" numpy;  check "main cuda12 has numpy" $?
has_pkg "$DIR/main/requirements-cuda12.txt" scipy;  check "main cuda12 has scipy" $?

# cuda12 variant has colorama (proxy for extra CUDA packages), cpu does not
has_pkg "$DIR/main/requirements-cuda12.txt" colorama
check "main cuda12 has colorama (cuda-specific dep)" $?

! has_pkg "$DIR/main/requirements-cpu.txt" colorama
check "main cpu does NOT have colorama" $?

echo ""

# ── Step 4: Main — negative test (both conflicting extras) ───────
echo -e "${BOLD}Step 4: Main — both conflicting extras rejected${RESET}"

if $UV export --package trainer --extra cpu --extra cuda12 --no-hashes \
    --directory "$DIR/main" -o /dev/null 2>&1; then
    check "Main rejects cpu + cuda12 together" 1
else
    check "Main rejects cpu + cuda12 together" 0
fi
echo ""

# ── Step 5: Legacy workspace — export ────────────────────────────
echo -e "${BOLD}Step 5: Legacy workspace export (cuda11)${RESET}"

$UV export --package old-model --extra cuda11 --no-hashes --no-emit-workspace \
    --directory "$DIR/legacy" -o "$DIR/legacy/requirements-cuda11.txt" 2>&1
check "Legacy: export cuda11 variant" $?

has_pkg "$DIR/legacy/requirements-cuda11.txt" numpy;   check "legacy cuda11 has numpy" $?
has_pkg "$DIR/legacy/requirements-cuda11.txt" urllib3;  check "legacy cuda11 has urllib3" $?

echo ""

# ── Step 6: Cross-workspace — urllib3 versions differ ─────────────
echo -e "${BOLD}Step 6: Cross-workspace version isolation${RESET}"

urllib3_main=$(get_version "$DIR/main/requirements-cpu.txt" urllib3)
urllib3_legacy=$(get_version "$DIR/legacy/requirements-cuda11.txt" urllib3)

echo "  Main (cpu) urllib3:    $urllib3_main"
echo "  Legacy (cuda11) urllib3: $urllib3_legacy"

[ -n "$urllib3_main" ] && [ -n "$urllib3_legacy" ]
check "Both workspaces have urllib3" $?

[ "$urllib3_main" != "$urllib3_legacy" ]
check "urllib3 versions differ between main and legacy" $?

echo ""

# ── Step 7: Two-step export (uv export → uv pip compile) ─────────
echo -e "${BOLD}Step 7: Two-step platform-specific export${RESET}"

# Main cuda12 → linux
$UV pip compile "$DIR/main/requirements-cuda12.txt" \
    --python-platform x86_64-unknown-linux-gnu --no-header \
    -o "$DIR/main/requirements-linux-cuda12.txt" 2>&1
check "Compile main cuda12 for linux" $?

# Main cpu → darwin
$UV pip compile "$DIR/main/requirements-cpu.txt" \
    --python-platform aarch64-apple-darwin --no-header \
    -o "$DIR/main/requirements-darwin.txt" 2>&1
check "Compile main cpu for darwin" $?

# Legacy cuda11 → linux
$UV pip compile "$DIR/legacy/requirements-cuda11.txt" \
    --python-platform x86_64-unknown-linux-gnu --no-header \
    -o "$DIR/legacy/requirements-linux-cuda11.txt" 2>&1
check "Compile legacy cuda11 for linux" $?

# Verify platform files have correct content
has_pkg "$DIR/main/requirements-linux-cuda12.txt" numpy
check "main linux-cuda12 has numpy" $?

has_pkg "$DIR/main/requirements-linux-cuda12.txt" colorama
check "main linux-cuda12 has colorama" $?

has_pkg "$DIR/legacy/requirements-linux-cuda11.txt" numpy
check "legacy linux-cuda11 has numpy" $?

# Versions should still differ in platform files
urllib3_main_linux=$(get_version "$DIR/main/requirements-linux-cuda12.txt" urllib3)
urllib3_legacy_linux=$(get_version "$DIR/legacy/requirements-linux-cuda11.txt" urllib3)
[ "$urllib3_main_linux" != "$urllib3_legacy_linux" ]
check "urllib3 still differs in platform-specific files" $?

echo ""

# ── Display key files ─────────────────────────────────────────────
echo -e "${BOLD}Generated files${RESET}"
echo ""
for f in main/requirements-linux-cuda12.txt main/requirements-darwin.txt legacy/requirements-linux-cuda11.txt; do
    echo "--- $f ---"
    cat "$DIR/$f"
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
    echo "Conclusion: Pattern 5 works as described."
    echo "  - Two separate workspaces lock independently."
    echo "  - Main workspace uses [tool.uv] conflicts for mutually exclusive extras."
    echo "  - Legacy workspace uses simple extras (no conflicts needed)."
    echo "  - Cross-workspace: different versions of the same package resolve correctly."
    echo "  - Two-step export (uv export → uv pip compile) works per workspace per variant."
    exit 0
else
    echo -e "${RED}${BOLD}SOME CHECKS FAILED${RESET}"
    exit 1
fi
