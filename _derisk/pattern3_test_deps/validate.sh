#!/usr/bin/env bash
# validate.sh — Pattern 3: Multiple Products, Additional Test Dependencies
#
# Tests the core claims from multi-project-patterns.md:
#   1. Test folders with their own pyproject.toml participate in workspace resolution
#   2. One uv lock resolves everything (production + test deps)
#   3. Production-only export excludes test-only deps
#   4. Per-package export isolates just that package's deps
#
# Also tests the gotcha discovered during prototyping:
#   5. [dependency-groups]-only pyproject.toml (no [project]) FAILS as workspace member
#   6. [dependency-groups] WITH [project] stub works correctly
#   7. --no-dev excludes [dependency-groups] but NOT [project].dependencies
#
# Usage: cd pattern3_test_deps && bash validate.sh

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

echo -e "${BOLD}=== Pattern 3: Test Dependencies Validation ===${RESET}"
echo ""

# ── Step 1: uv lock ──────────────────────────────────────────────
echo -e "${BOLD}Step 1: uv lock${RESET}"
if $UV lock 2>&1; then
    echo ""
    check "uv lock succeeds with test folders in workspace" 0
else
    echo ""
    check "uv lock succeeds with test folders in workspace" 1
    echo "FATAL: uv lock failed."
    exit 1
fi
echo ""

# ── Step 2: Full export (everything) ─────────────────────────────
echo -e "${BOLD}Step 2: Full export (all packages, all groups)${RESET}"

$UV export --all-packages --all-extras --all-groups \
    --no-hashes --no-emit-workspace -o requirements-everything.txt 2>&1
check "Export everything" $?

# Should have production deps AND test deps
has_pkg requirements-everything.txt requests;  check "everything has requests (core prod dep)" $?
has_pkg requirements-everything.txt httpx;     check "everything has httpx (integration-tests)" $?
has_pkg requirements-everything.txt respx;     check "everything has respx (integration-tests)" $?
has_pkg requirements-everything.txt locust;    check "everything has locust (load-tests dep group)" $?

echo ""

# ── Step 3: Production-only export ───────────────────────────────
# --no-dev excludes [dependency-groups] but NOT [project].dependencies
echo -e "${BOLD}Step 3: Production-only export (--no-dev)${RESET}"

$UV export --all-packages --all-extras --no-dev \
    --no-hashes --no-emit-workspace -o requirements-no-dev.txt 2>&1
check "Export with --no-dev" $?

has_pkg requirements-no-dev.txt requests;  check "no-dev has requests (core prod dep)" $?

# Gotcha: httpx/respx are in [project].dependencies of integration-tests,
# so --no-dev does NOT exclude them. Only [dependency-groups] deps are excluded.
has_pkg requirements-no-dev.txt httpx
check "no-dev STILL has httpx ([project].dependencies — NOT excluded by --no-dev)" $?

! has_pkg requirements-no-dev.txt locust
check "no-dev does NOT have locust ([dependency-groups] — excluded by --no-dev)" $?

echo ""

# ── Step 4: Per-package export (cleanest production) ─────────────
echo -e "${BOLD}Step 4: Per-package export (core only)${RESET}"

$UV export --package core --no-dev --no-hashes --no-emit-workspace \
    -o requirements-core-only.txt 2>&1
check "Export core package only" $?

has_pkg requirements-core-only.txt requests
check "core-only has requests" $?

! has_pkg requirements-core-only.txt httpx
check "core-only does NOT have httpx" $?

! has_pkg requirements-core-only.txt locust
check "core-only does NOT have locust" $?

! has_pkg requirements-core-only.txt respx
check "core-only does NOT have respx" $?

echo ""
echo "--- requirements-core-only.txt ---"
cat requirements-core-only.txt
echo ""

# ── Step 5: Dependency group isolation ────────────────────────────
echo -e "${BOLD}Step 5: Export only a specific dependency group${RESET}"

$UV export --all-packages --only-group test \
    --no-hashes --no-emit-workspace -o requirements-group-test.txt 2>&1
check "Export --only-group test" $?

has_pkg requirements-group-test.txt locust
check "group-test has locust" $?

# requests IS present because locust depends on it transitively
has_pkg requirements-group-test.txt requests
check "group-test has requests (transitive via locust)" $?

# httpx is NOT present — it's in integration-tests' [project].dependencies,
# not in any [dependency-groups]
! has_pkg requirements-group-test.txt httpx
check "group-test does NOT have httpx (not in any group)" $?

echo ""

# ── Step 6: Gotcha — [dependency-groups]-only FAILS ───────────────
# A pyproject.toml with ONLY [dependency-groups] and no [project] table
# cannot be a uv workspace member.
echo -e "${BOLD}Step 6: Gotcha — [dependency-groups]-only fails${RESET}"

# Create a temporary workspace that references a groups-only pyproject
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

mkdir -p "$TMPDIR/bare-group"

# Root workspace referencing the bare-group member
cat > "$TMPDIR/pyproject.toml" << 'TOML'
[project]
name = "gotcha-test-root"
version = "0.0.0"
requires-python = ">=3.11"

[tool.uv.workspace]
members = ["bare-group"]
TOML

# A pyproject with ONLY [dependency-groups], no [project]
cat > "$TMPDIR/bare-group/pyproject.toml" << 'TOML'
[dependency-groups]
test = ["pytest"]
TOML

if $UV lock --directory "$TMPDIR" 2>&1; then
    check "[dependency-groups]-only pyproject FAILS as workspace member" 1
    echo "  UNEXPECTED: uv accepted a workspace member with no [project] table."
    echo "  This means the gotcha documented in FINDINGS.md may no longer apply."
else
    check "[dependency-groups]-only pyproject FAILS as workspace member" 0
fi

echo ""

# ── Step 7: Gotcha workaround — [project] stub + [dependency-groups] ─
echo -e "${BOLD}Step 7: Gotcha workaround — [project] stub works${RESET}"

# The actual load-tests/pyproject.toml uses this workaround.
# It already passed in Step 1 (uv lock succeeded with it in the workspace).
# Verify the specific structure is what we expect.
if grep -q '\[project\]' load-tests/pyproject.toml && \
   grep -q '\[dependency-groups\]' load-tests/pyproject.toml; then
    check "load-tests has both [project] stub and [dependency-groups]" 0
else
    check "load-tests has both [project] stub and [dependency-groups]" 1
fi

# Verify it's tracked as a virtual source in the lock file
if grep -q 'virtual = "load-tests"' uv.lock; then
    check "load-tests tracked as virtual source in lock file" 0
else
    check "load-tests tracked as virtual source in lock file" 1
fi

echo ""

# ── Step 8: Workspace members excluded from exports ───────────────
echo -e "${BOLD}Step 8: Workspace members excluded${RESET}"

! has_pkg requirements-everything.txt core
check "workspace member 'core' excluded from export" $?

! has_pkg requirements-everything.txt integration-tests
check "workspace member 'integration-tests' excluded from export" $?

! has_pkg requirements-everything.txt load-tests
check "workspace member 'load-tests' excluded from export" $?

echo ""

# ── Summary ───────────────────────────────────────────────────────
echo -e "${BOLD}=== Summary ===${RESET}"
echo -e "  Passed: ${GREEN}${pass}${RESET}"
echo -e "  Failed: ${RED}${fail}${RESET}"
echo ""

if [ "$fail" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}ALL CHECKS PASSED${RESET}"
    echo ""
    echo "Conclusion: Pattern 3 works as described, with one documented gotcha."
    echo "  - Test folders participate in workspace resolution."
    echo "  - --no-dev excludes [dependency-groups] but NOT [project].dependencies."
    echo "  - --package <name> gives the cleanest production-only export."
    echo "  - --only-group <name> isolates just one dependency group."
    echo "  - GOTCHA: [dependency-groups]-only pyproject.toml (no [project]) fails."
    echo "    Workaround: add a minimal [project] stub alongside [dependency-groups]."
    exit 0
else
    echo -e "${RED}${BOLD}SOME CHECKS FAILED${RESET}"
    exit 1
fi
