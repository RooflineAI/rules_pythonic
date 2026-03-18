#!/usr/bin/env bash
# Experiment 2: Smarter first-party dep handling in install_venv.py
#
# Problem: pyproject.toml lists both first-party and third-party deps:
#   dependencies = ["torch>=2.1", "numpy", "attic-rt"]
# install_venv.py tries to match "attic-rt" against wheel files and fails.
#
# Tests:
# A) Current skip-list approach works
# B) Improved "match-or-verify" approach: skip if in first-party labels, fail if genuinely missing
# C) Edge cases: name normalization, version specifiers, extras

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Experiment 2: First-Party Dep Handling ==="
echo ""

# --- Setup ---
rm -rf wheels/ venv_out/
mkdir -p wheels

# Create some fake wheel files (just empty files with correct names)
# These simulate what @pypi would provide
touch wheels/torch-2.1.0-cp311-cp311-macosx_14_0_arm64.whl
touch wheels/numpy-1.26.0-cp311-cp311-macosx_14_0_arm64.whl
touch wheels/pytest-7.4.0-py3-none-any.whl
touch wheels/pluggy-1.3.0-py3-none-any.whl
touch wheels/iniconfig-2.0.0-py3-none-any.whl

# Note: NO wheel for "attic-rt" or "attic" (they're first-party)
# Note: NO wheel for "nonexistent-pkg" (genuinely missing)

# Create test pyproject.toml
cat > pyproject_good.toml <<'EOF'
[project]
name = "attic"
dependencies = [
    "torch>=2.1",
    "numpy",
    "attic-rt",
]

[project.optional-dependencies]
test = ["pytest>=7.0"]
EOF

cat > pyproject_missing.toml <<'EOF'
[project]
name = "attic"
dependencies = [
    "torch>=2.1",
    "numpy",
    "attic-rt",
    "nonexistent-pkg>=1.0",
]

[project.optional-dependencies]
test = ["pytest>=7.0"]
EOF

cat > pyproject_edge_cases.toml <<'EOF'
[project]
name = "attic"
dependencies = [
    "Attic-RT",
    "my.dotted.pkg",
    "pkg-with-extras[gpu,cuda]>=2.0",
    "conditional-pkg; python_version >= '3.11'",
]
EOF

echo "--- Test A: Current skip-list approach ---"
python3 -c "
import pathlib, tomllib

def normalize(name):
    return name.lower().replace('-', '_').replace('.', '_')

def extract_dep_name(dep_spec):
    for ch in '><=!;[':
        dep_spec = dep_spec.split(ch)[0]
    return dep_spec.strip()

skip_packages = {'attic_rt', 'attic'}
wheel_dir = pathlib.Path('wheels')
pp = tomllib.loads(pathlib.Path('pyproject_good.toml').read_text())

needed = set()
for dep in pp.get('project', {}).get('dependencies', []):
    name = normalize(extract_dep_name(dep))
    if name not in skip_packages:
        needed.add(name)
for dep in pp['project'].get('optional-dependencies', {}).get('test', []):
    name = normalize(extract_dep_name(dep))
    if name not in skip_packages:
        needed.add(name)

print(f'  Needed (after skip): {sorted(needed)}')

matched = []
for whl in wheel_dir.glob('*.whl'):
    whl_name = normalize(whl.name.split('-')[0])
    if whl_name in needed:
        matched.append(whl.name)

print(f'  Matched wheels: {sorted(matched)}')
unmatched = needed - {normalize(w.split('-')[0]) for w in matched}
print(f'  Unmatched: {sorted(unmatched)}')
if not unmatched:
    print('  PASS: All deps resolved')
else:
    print(f'  FAIL: Unmatched deps: {unmatched}')
"
echo ""

echo "--- Test B: Improved match-or-verify approach ---"
python3 << 'PYEOF'
import pathlib, tomllib

def normalize(name):
    return name.lower().replace("-", "_").replace(".", "_")

def extract_dep_name(dep_spec):
    for ch in "><=!;[":
        dep_spec = dep_spec.split(ch)[0]
    return dep_spec.strip()

def resolve_deps(pyproject_path, wheel_dir, first_party_names):
    """
    Improved resolver:
    - If dep matches a wheel: install it
    - If dep is in first_party_names: skip (handled via PYTHONPATH)
    - If dep matches neither: ERROR (genuinely missing from requirements.txt)
    """
    pp = tomllib.loads(pathlib.Path(pyproject_path).read_text())

    # Collect all dep names
    all_deps = set()
    for dep in pp.get("project", {}).get("dependencies", []):
        all_deps.add(normalize(extract_dep_name(dep)))
    for dep in pp["project"].get("optional-dependencies", {}).get("test", []):
        all_deps.add(normalize(extract_dep_name(dep)))

    # Build wheel index
    wheel_index = {}
    for whl in pathlib.Path(wheel_dir).glob("*.whl"):
        whl_name = normalize(whl.name.split("-")[0])
        wheel_index[whl_name] = whl

    # Normalize first-party names
    fp_normalized = {normalize(n) for n in first_party_names}

    # Classify each dep
    to_install = []
    skipped_firstparty = []
    missing = []

    for dep_name in sorted(all_deps):
        if dep_name in wheel_index:
            to_install.append((dep_name, wheel_index[dep_name]))
        elif dep_name in fp_normalized:
            skipped_firstparty.append(dep_name)
        else:
            missing.append(dep_name)

    return to_install, skipped_firstparty, missing

# Test with good pyproject (attic-rt is first-party)
print("  Test B.1: pyproject with first-party dep (should pass)")
install, skip, miss = resolve_deps(
    "pyproject_good.toml", "wheels",
    first_party_names=["attic-rt", "attic"]
)
print(f"    Install: {[n for n,_ in install]}")
print(f"    Skip (first-party): {skip}")
print(f"    Missing: {miss}")
if not miss:
    print("    PASS")
else:
    print(f"    FAIL: missing deps: {miss}")
print()

# Test with missing dep (nonexistent-pkg is NOT first-party)
print("  Test B.2: pyproject with genuinely missing dep (should fail)")
install, skip, miss = resolve_deps(
    "pyproject_missing.toml", "wheels",
    first_party_names=["attic-rt", "attic"]
)
print(f"    Install: {[n for n,_ in install]}")
print(f"    Skip (first-party): {skip}")
print(f"    Missing: {miss}")
if miss:
    print(f"    PASS: Correctly caught missing dep: {miss}")
    print(f"    Error message would be:")
    for m in miss:
        print(f'      ERROR: package "{m}" required by pyproject.toml but not found')
        print(f'             in @pypi wheels and not a first-party dep.')
        print(f'             Add it to requirements.txt or deps = [...] in BUILD.')
else:
    print("    FAIL: Should have caught missing dep")
print()

# Test edge cases
print("  Test B.3: Name normalization edge cases")
install, skip, miss = resolve_deps(
    "pyproject_edge_cases.toml", "wheels",
    first_party_names=["attic-rt", "attic", "my-dotted-pkg", "conditional-pkg"]
)
print(f"    Install: {[n for n,_ in install]}")
print(f"    Skip (first-party): {skip}")
print(f"    Missing: {miss}")
# "Attic-RT" -> "attic_rt" (in first-party)
# "my.dotted.pkg" -> "my_dotted_pkg" (in first-party)
# "pkg-with-extras[gpu,cuda]>=2.0" -> "pkg_with_extras" (missing - no wheel)
# "conditional-pkg; python_version >= '3.11'" -> "conditional_pkg" (in first-party)
if "attic_rt" in skip and "my_dotted_pkg" in skip and "conditional_pkg" in skip:
    print("    PASS: Normalization handles case, dots, hyphens, extras, markers")
else:
    print("    FAIL: Normalization issue")
if "pkg_with_extras" in miss:
    print("    PASS: Correctly catches missing 'pkg_with_extras' (not first-party, no wheel)")
else:
    print("    Note: 'pkg_with_extras' classification: install={[n for n,_ in install]} skip={skip} miss={miss}")
PYEOF
echo ""

echo "=== Experiment 2 Complete ==="
