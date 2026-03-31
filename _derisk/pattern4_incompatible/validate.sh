#!/usr/bin/env bash
# Validation script for Pattern 4: Incompatible Dependencies
# Two separate uv workspaces resolving different pydantic versions.
#
# Usage: bash validate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UV="${UV:-uv}"

echo "=== Pattern 4: Incompatible Dependencies Validation ==="
echo ""

# Step 1: Lock main workspace
echo "--- Step 1: Locking main workspace ---"
$UV lock --directory "$SCRIPT_DIR/main" 2>&1
echo ""

# Step 2: Lock legacy workspace
echo "--- Step 2: Locking legacy workspace ---"
$UV lock --directory "$SCRIPT_DIR/legacy" 2>&1
echo ""

# Step 3: Verify pydantic versions
echo "--- Step 3: Verifying pydantic versions ---"
MAIN_PYDANTIC=$(grep '^version = ' "$SCRIPT_DIR/main/uv.lock" | head -1)
# More precise: search for the pydantic package block
MAIN_PD_VER=$(awk '/^\[\[package\]\]/{p=0} /name = "pydantic"$/{p=1} p && /^version =/{print $3; exit}' "$SCRIPT_DIR/main/uv.lock" | tr -d '"')
LEGACY_PD_VER=$(awk '/^\[\[package\]\]/{p=0} /name = "pydantic"$/{p=1} p && /^version =/{print $3; exit}' "$SCRIPT_DIR/legacy/uv.lock" | tr -d '"')

echo "Main workspace pydantic:   $MAIN_PD_VER"
echo "Legacy workspace pydantic: $LEGACY_PD_VER"

if [[ "$MAIN_PD_VER" == 2.* ]] && [[ "$LEGACY_PD_VER" == 1.* ]]; then
    echo "PASS: Main has pydantic 2.x, legacy has pydantic 1.x"
else
    echo "FAIL: Unexpected pydantic versions"
    exit 1
fi
echo ""

# Step 4: Export requirements
echo "--- Step 4: Exporting requirements ---"
$UV export --all-extras --no-hashes --all-packages \
    --directory "$SCRIPT_DIR/main" \
    -o "$SCRIPT_DIR/main/requirements.txt" 2>&1
$UV export --all-extras --no-hashes --all-packages \
    --directory "$SCRIPT_DIR/legacy" \
    -o "$SCRIPT_DIR/legacy/requirements.txt" 2>&1
echo ""

# Step 5: Verify exported requirements
echo "--- Step 5: Verifying exported requirements ---"
MAIN_REQ_PD=$(grep '^pydantic==' "$SCRIPT_DIR/main/requirements.txt")
LEGACY_REQ_PD=$(grep '^pydantic==' "$SCRIPT_DIR/legacy/requirements.txt")

echo "Main requirements.txt:   $MAIN_REQ_PD"
echo "Legacy requirements.txt: $LEGACY_REQ_PD"

if echo "$MAIN_REQ_PD" | grep -q 'pydantic==2\.' && echo "$LEGACY_REQ_PD" | grep -q 'pydantic==1\.'; then
    echo "PASS: Exported requirements have different pydantic versions"
else
    echo "FAIL: Exported requirements do not match expected versions"
    exit 1
fi
echo ""

# Step 6: Verify shared-core is in both
echo "--- Step 6: Verifying shared-core in both workspaces ---"
if grep -q 'shared-core' "$SCRIPT_DIR/main/uv.lock" && grep -q 'shared-core' "$SCRIPT_DIR/legacy/uv.lock"; then
    echo "PASS: shared-core is a member of both workspaces"
else
    echo "FAIL: shared-core not found in both lockfiles"
    exit 1
fi

if grep -q 'shared-core' "$SCRIPT_DIR/main/requirements.txt" && grep -q 'shared-core' "$SCRIPT_DIR/legacy/requirements.txt"; then
    echo "PASS: shared-core appears in both requirements.txt"
else
    echo "FAIL: shared-core not in both requirements.txt"
    exit 1
fi
echo ""

echo "=== All validations passed ==="
