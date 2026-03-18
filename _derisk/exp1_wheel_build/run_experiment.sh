#!/usr/bin/env bash
# Experiment 1: Can uv build --wheel work in a Bazel-sandbox-like environment?
#
# Tests:
# A) uv build --wheel with a normal source tree
# B) uv build --wheel from a symlinked source tree (simulating Bazel sandbox)
# C) VERSION file with relative path (dynamic versioning)
# D) --no-build-isolation (setuptools must be pre-available)
# E) Without setuptools (--no-build-isolation should fail)
# F) With isolation (default — uv fetches setuptools)
# G) Combined: symlinked sandbox + --no-build-isolation

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

UV=uv
PYTHON=python3.11

echo "=== Experiment 1: Wheel Build Action ==="
echo ""

# --- Setup: Create a minimal Python package ---
echo "--- Setup: Creating test package ---"
rm -rf pkg/ sandbox/ dist/ dist_sandbox/ dist_noiso/ dist_nosetup/ dist_iso/ dist_combined/ build_venv/ bare_venv/
mkdir -p pkg/src/mypkg

cat > pkg/VERSION <<'EOF'
1.2.3
EOF

cat > pkg/pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools>=68.0"]
build-backend = "setuptools.build_meta"

[project]
name = "mypkg"
dynamic = ["version"]

[tool.setuptools.dynamic]
version = {file = "VERSION"}

[tool.setuptools.packages.find]
where = ["src"]
EOF

cat > pkg/src/mypkg/__init__.py <<'EOF'
def hello():
    return "hello from mypkg"
EOF

echo "  Package structure:"
find pkg/ -type f | sort | sed 's/^/    /'
echo ""

# --- Test A: Normal source tree ---
echo "--- Test A: uv build --wheel (normal source tree) ---"
rm -rf dist/
t0=$(python3 -c "import time; print(time.time())")
if $UV build --wheel --out-dir dist/ pkg/ 2>&1; then
    t1=$(python3 -c "import time; print(time.time())")
    echo "  PASS: Wheel built successfully"
    ls -la dist/*.whl 2>/dev/null | sed 's/^/    /'
    echo "  Time: $(python3 -c "print(f'{$t1 - $t0:.2f}s')")"
else
    echo "  FAIL: uv build failed"
fi
echo ""

# --- Test B: Symlinked source tree (simulating Bazel sandbox) ---
echo "--- Test B: uv build --wheel (symlinked source tree) ---"
rm -rf sandbox/ dist_sandbox/
mkdir -p sandbox/pkg
# Bazel creates symlinks to individual files, not directory symlinks
for f in $(find pkg/ -type f); do
    target_dir="sandbox/$(dirname "$f")"
    mkdir -p "$target_dir"
    ln -s "$SCRIPT_DIR/$f" "$target_dir/$(basename "$f")"
done

echo "  Sandbox structure (symlinks):"
find sandbox/ -type l | sort | while read f; do
    echo "    $f -> $(readlink "$f")"
done
echo ""

if $UV build --wheel --out-dir dist_sandbox/ sandbox/pkg/ 2>&1; then
    echo "  PASS: Wheel built from symlinked tree"
    ls -la dist_sandbox/*.whl 2>/dev/null | sed 's/^/    /'
else
    echo "  FAIL: uv build failed with symlinked tree"
fi
echo ""

# --- Test C: VERSION file with relative path ---
echo "--- Test C: Dynamic version from VERSION file ---"
if ls dist/*.whl 2>/dev/null | head -1 | grep -q "1.2.3"; then
    echo "  PASS: Wheel has correct version 1.2.3 from VERSION file"
else
    echo "  FAIL or N/A: Version not correctly read from VERSION file"
    ls dist/*.whl 2>/dev/null | sed 's/^/    /' || echo "    (no wheels)"
fi
echo ""

# --- Test D: --no-build-isolation ---
echo "--- Test D: uv build --wheel --no-build-isolation ---"
rm -rf dist_noiso/

# Create a venv with setuptools available
$UV venv build_venv --python $PYTHON --quiet 2>&1
$UV pip install "setuptools>=68.0" --python build_venv/bin/python3 --quiet 2>&1

echo "  Setuptools in build_venv:"
build_venv/bin/python3 -c "import setuptools; print(f'    version: {setuptools.__version__}')" 2>&1

if $UV build --wheel --no-build-isolation --python build_venv/bin/python3 --out-dir dist_noiso/ pkg/ 2>&1; then
    echo "  PASS: --no-build-isolation works with pre-installed setuptools"
    ls -la dist_noiso/*.whl 2>/dev/null | sed 's/^/    /'
else
    echo "  FAIL: --no-build-isolation failed"
fi
echo ""

# --- Test E: Without setuptools (--no-build-isolation)? ---
echo "--- Test E: --no-build-isolation WITHOUT setuptools ---"
rm -rf dist_nosetup/ bare_venv/
$UV venv bare_venv --python $PYTHON --quiet 2>&1

set +e  # Don't exit on failure for this test
$UV build --wheel --no-build-isolation --python bare_venv/bin/python3 --out-dir dist_nosetup/ pkg/ 2>&1
exit_code=$?
set -e

if [ $exit_code -ne 0 ]; then
    echo "  EXPECTED FAIL: Correctly fails without setuptools"
    echo "  Conclusion: Bazel rule MUST provide setuptools as a build dep"
else
    echo "  UNEXPECTED PASS: Built without setuptools?"
fi
echo ""

# --- Test F: uv build WITH isolation (default) ---
echo "--- Test F: uv build WITH isolation (default behavior) ---"
rm -rf dist_iso/
if $UV build --wheel --out-dir dist_iso/ --python $PYTHON pkg/ 2>&1; then
    echo "  PASS: uv auto-fetches setuptools with build isolation"
    echo "  Implication: if we allow network during wheel build, setuptools is automatic"
    echo "  For hermetic builds: --no-build-isolation + pre-downloaded setuptools"
else
    echo "  FAIL: uv build with isolation failed"
fi
echo ""

# --- Test G: Symlinked sandbox + --no-build-isolation ---
echo "--- Test G: COMBINED — symlinked sandbox + --no-build-isolation ---"
rm -rf dist_combined/
if $UV build --wheel --no-build-isolation --python build_venv/bin/python3 --out-dir dist_combined/ sandbox/pkg/ 2>&1; then
    echo "  PASS: Full Bazel simulation works"
    ls -la dist_combined/*.whl 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Wheel contents:"
    python3 -c "
import zipfile, sys, pathlib
whl = list(pathlib.Path('dist_combined').glob('*.whl'))[0]
with zipfile.ZipFile(whl) as z:
    for name in sorted(z.namelist()):
        print(f'    {name}')
"
    echo ""
    echo "  Verify version in wheel metadata:"
    python3 -c "
import zipfile, pathlib
whl = list(pathlib.Path('dist_combined').glob('*.whl'))[0]
with zipfile.ZipFile(whl) as z:
    for name in z.namelist():
        if name.endswith('METADATA'):
            meta = z.read(name).decode()
            for line in meta.splitlines():
                if line.startswith('Version:') or line.startswith('Name:'):
                    print(f'    {line}')
"
else
    echo "  FAIL: Combined simulation failed"
fi
echo ""

# --- Test H: VERSION file from a DIFFERENT location (Bazel scenario) ---
echo "--- Test H: VERSION file at repo root (../../VERSION pattern) ---"
rm -rf dist_version/
mkdir -p sandbox_v2/repo_root/packages/mypkg/src/mypkg

echo "2.0.0-beta1" > sandbox_v2/repo_root/VERSION

cat > sandbox_v2/repo_root/packages/mypkg/pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools>=68.0"]
build-backend = "setuptools.build_meta"

[project]
name = "mypkg"
dynamic = ["version"]

[tool.setuptools.dynamic]
version = {file = "../../VERSION"}

[tool.setuptools.packages.find]
where = ["src"]
EOF

cat > sandbox_v2/repo_root/packages/mypkg/src/mypkg/__init__.py <<'EOF'
def hello():
    return "hello v2"
EOF

echo "  Testing ../../VERSION relative path..."
if $UV build --wheel --out-dir dist_version/ sandbox_v2/repo_root/packages/mypkg/ 2>&1; then
    echo "  PASS: ../../VERSION works"
    ls dist_version/*.whl | sed 's/^/    /'
    python3 -c "
import zipfile, pathlib
whl = list(pathlib.Path('dist_version').glob('*.whl'))[0]
with zipfile.ZipFile(whl) as z:
    for name in z.namelist():
        if name.endswith('METADATA'):
            meta = z.read(name).decode()
            for line in meta.splitlines():
                if line.startswith('Version:'):
                    print(f'    {line}')
"
else
    echo "  FAIL: ../../VERSION relative path doesn't work"
    echo "  This means: VERSION file needs special handling in Bazel sandbox"
fi
echo ""

# --- Test I: Symlinked sandbox with ../../VERSION ---
echo "--- Test I: Symlinked sandbox with ../../VERSION ---"
rm -rf dist_version_sym/ sandbox_v3/
mkdir -p sandbox_v3/repo_root/packages/mypkg/src/mypkg

# Symlink everything
ln -s "$SCRIPT_DIR/sandbox_v2/repo_root/VERSION" sandbox_v3/repo_root/VERSION
ln -s "$SCRIPT_DIR/sandbox_v2/repo_root/packages/mypkg/pyproject.toml" sandbox_v3/repo_root/packages/mypkg/pyproject.toml
ln -s "$SCRIPT_DIR/sandbox_v2/repo_root/packages/mypkg/src/mypkg/__init__.py" sandbox_v3/repo_root/packages/mypkg/src/mypkg/__init__.py

if $UV build --wheel --out-dir dist_version_sym/ sandbox_v3/repo_root/packages/mypkg/ 2>&1; then
    echo "  PASS: Symlinked sandbox + ../../VERSION works"
    python3 -c "
import zipfile, pathlib
whl = list(pathlib.Path('dist_version_sym').glob('*.whl'))[0]
with zipfile.ZipFile(whl) as z:
    for name in z.namelist():
        if name.endswith('METADATA'):
            meta = z.read(name).decode()
            for line in meta.splitlines():
                if line.startswith('Version:'):
                    print(f'    {line}')
"
else
    echo "  FAIL: Symlinked sandbox + ../../VERSION fails"
    echo "  This is the Bazel scenario — VERSION file must be declared input"
fi
echo ""

echo "=== Experiment 1 Complete ==="
