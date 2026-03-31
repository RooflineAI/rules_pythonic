#!/usr/bin/env bash
# validate.sh — Pattern 1: Single Product, Shared Dependencies
#
# Tests the core claims from multi-project-patterns.md:
#   1. One uv lock resolves all packages together
#   2. uv export produces a superset requirements file
#   3. Platform-specific markers are present in the universal export
#   4. Per-platform files can be produced via uv pip compile --python-platform
#   5. Per-package export isolates just that package's deps
#   6. Workspace members (first-party) are excluded from export
#   7. Shared deps resolve to identical versions across packages
#
# FINDING: uv export does NOT support --python-platform. The readme's command
# syntax is wrong. Two alternatives work:
#   A) uv export (universal with markers) — pip.parse() handles markers
#   B) uv export | uv pip compile --python-platform — per-platform files
#
# Usage: cd pattern1_single_product && bash validate.sh

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

# Match a package at the start of a line, followed by == or >= or > or space or ;
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

echo -e "${BOLD}=== Pattern 1: Single Product Validation ===${RESET}"
echo ""

# ── Step 1: uv lock ──────────────────────────────────────────────
echo -e "${BOLD}Step 1: uv lock${RESET}"
if $UV lock 2>&1; then
    echo ""
    check "uv lock succeeds for single workspace" 0
else
    echo ""
    check "uv lock succeeds for single workspace" 1
    echo "FATAL: uv lock failed. Cannot proceed."
    exit 1
fi
echo ""

# ── Step 2: Universal export ─────────────────────────────────────
# uv export produces a universal file with environment markers.
echo -e "${BOLD}Step 2: Universal export (all packages, all extras)${RESET}"

$UV export --all-packages --all-extras --no-hashes --no-emit-workspace \
    -o requirements-all.txt 2>&1
check "Export all-packages requirements" $?

echo ""
echo "--- requirements-all.txt ---"
cat requirements-all.txt
echo ""

# ── Step 3: Platform markers are present ──────────────────────────
echo -e "${BOLD}Step 3: Universal export contains platform markers${RESET}"

# colorama has a sys_platform == 'win32' marker
has_pkg requirements-all.txt colorama
check "Universal export includes colorama (with win32 marker)" $?

grep -q "sys_platform == 'win32'" requirements-all.txt
check "Marker sys_platform == 'win32' is present" $?

echo ""

# ── Step 4: Per-platform files via uv pip compile ─────────────────
# FINDING: uv export does NOT support --python-platform.
# Alternative: pipe through uv pip compile --python-platform.
echo -e "${BOLD}Step 4: Per-platform files via uv pip compile --python-platform${RESET}"

$UV pip compile requirements-all.txt \
    --python-platform x86_64-unknown-linux-gnu --no-header \
    -o requirements-linux.txt 2>&1
check "Compile linux requirements" $?

$UV pip compile requirements-all.txt \
    --python-platform aarch64-apple-darwin --no-header \
    -o requirements-darwin.txt 2>&1
check "Compile darwin requirements" $?

# Colorama (win32-only) should be ABSENT on both platforms
! has_pkg requirements-linux.txt colorama
check "Linux file does NOT include colorama (win32-only)" $?

! has_pkg requirements-darwin.txt colorama
check "Darwin file does NOT include colorama (win32-only)" $?

# Core deps should be present on both
for platform_file in requirements-linux.txt requirements-darwin.txt; do
    platform=$(basename "$platform_file" .txt | sed 's/requirements-//')
    has_pkg "$platform_file" requests;  check "$platform contains requests" $?
    has_pkg "$platform_file" pydantic;  check "$platform contains pydantic" $?
    has_pkg "$platform_file" fastapi;   check "$platform contains fastapi" $?
    has_pkg "$platform_file" click;     check "$platform contains click" $?
done

echo ""
echo "--- requirements-linux.txt ---"
cat requirements-linux.txt
echo ""

# ── Step 5: Workspace members excluded ────────────────────────────
echo -e "${BOLD}Step 5: Workspace members excluded from export${RESET}"

! has_pkg requirements-all.txt core
check "all does NOT contain workspace member 'core'" $?

! has_pkg requirements-all.txt api
check "all does NOT contain workspace member 'api'" $?

! has_pkg requirements-all.txt cli
check "all does NOT contain workspace member 'cli'" $?

echo ""

# ── Step 6: Per-package export isolates deps ──────────────────────
echo -e "${BOLD}Step 6: Per-package export isolation${RESET}"

$UV export --package core --no-hashes --no-emit-workspace -o requirements-core.txt 2>&1
$UV export --package api --no-hashes --no-emit-workspace -o requirements-api.txt 2>&1
$UV export --package cli --no-hashes --no-emit-workspace -o requirements-cli.txt 2>&1

# Core: requests + pydantic, NOT fastapi
has_pkg requirements-core.txt requests;   check "core has requests" $?
has_pkg requirements-core.txt pydantic;   check "core has pydantic" $?
! has_pkg requirements-core.txt fastapi;  check "core does NOT have fastapi" $?

# CLI: click + core's deps, NOT fastapi
has_pkg requirements-cli.txt click;       check "cli has click" $?
has_pkg requirements-cli.txt requests;    check "cli has requests (transitive via core)" $?
! has_pkg requirements-cli.txt fastapi;   check "cli does NOT have fastapi" $?

echo ""

# ── Step 7: Version consistency ───────────────────────────────────
echo -e "${BOLD}Step 7: Version consistency across exports${RESET}"

pydantic_all=$(get_version requirements-all.txt pydantic)
pydantic_core=$(get_version requirements-core.txt pydantic)
pydantic_linux=$(get_version requirements-linux.txt pydantic)

echo "  pydantic: all=$pydantic_all | core=$pydantic_core | linux=$pydantic_linux"

[ "$pydantic_all" = "$pydantic_core" ] && [ "$pydantic_all" = "$pydantic_linux" ]
check "pydantic version identical across all, core, and linux exports" $?

requests_all=$(get_version requirements-all.txt requests)
requests_core=$(get_version requirements-core.txt requests)
requests_linux=$(get_version requirements-linux.txt requests)

echo "  requests: all=$requests_all | core=$requests_core | linux=$requests_linux"

[ "$requests_all" = "$requests_core" ] && [ "$requests_all" = "$requests_linux" ]
check "requests version identical across all, core, and linux exports" $?

echo ""

# ── Summary ───────────────────────────────────────────────────────
echo -e "${BOLD}=== Summary ===${RESET}"
echo -e "  Passed: ${GREEN}${pass}${RESET}"
echo -e "  Failed: ${RED}${fail}${RESET}"
echo ""

if [ "$fail" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}ALL CHECKS PASSED${RESET}"
    echo ""
    echo "Conclusion: Pattern 1 works."
    echo "  - One uv lock resolves all workspace packages together."
    echo "  - uv export produces universal output with platform markers."
    echo "  - uv pip compile --python-platform strips markers to per-platform files."
    echo "  - Per-package export isolates just that package's dependencies."
    echo "  - Workspace members are excluded via --no-emit-workspace."
    echo "  - Shared deps resolve to identical versions across all exports."
    echo ""
    echo "README FIX NEEDED: uv export does NOT support --python-platform."
    echo "  Use: uv export → uv pip compile --python-platform"
    echo "  Or:  uv export (universal) → let pip.parse() handle markers"
    exit 0
else
    echo -e "${RED}${BOLD}SOME CHECKS FAILED${RESET}"
    exit 1
fi
