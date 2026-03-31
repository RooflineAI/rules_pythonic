#!/usr/bin/env python3
"""Build-time action: parse pyproject.toml, install matching wheels via uv."""

import pathlib
import subprocess
import sys
import tomllib
import time

uv = sys.argv[1]
python = sys.argv[2]
venv_dir = sys.argv[3]
wheel_dir = sys.argv[4]
pyproject_paths = sys.argv[5:]

# Parse --skip-packages if present
skip_packages = set()
remaining_pyprojects = []
i = 0
while i < len(pyproject_paths):
    if pyproject_paths[i] == "--skip-packages":
        i += 1
        while i < len(pyproject_paths) and not pyproject_paths[i].endswith(".toml"):
            skip_packages.add(pyproject_paths[i])
            i += 1
    else:
        remaining_pyprojects.append(pyproject_paths[i])
        i += 1
pyproject_paths = remaining_pyprojects


def normalize(name):
    return name.lower().replace("-", "_").replace(".", "_")


def extract_dep_name(dep_spec):
    for ch in "><=!;[":
        dep_spec = dep_spec.split(ch)[0]
    return dep_spec.strip()


# Collect dep names from all pyproject.toml files
needed = set()
for pp_path in pyproject_paths:
    pp = tomllib.loads(pathlib.Path(pp_path).read_text())
    for dep in pp.get("project", {}).get("dependencies", []):
        name = normalize(extract_dep_name(dep))
        if name not in skip_packages:
            needed.add(name)
    for dep in pp["project"].get("optional-dependencies", {}).get("test", []):
        name = normalize(extract_dep_name(dep))
        if name not in skip_packages:
            needed.add(name)

print(f"Needed packages (after skip): {sorted(needed)}")

# Match against available wheels
wheels_to_install = []
if pathlib.Path(wheel_dir).exists():
    for whl in pathlib.Path(wheel_dir).glob("*.whl"):
        whl_name = normalize(whl.name.split("-")[0])
        if whl_name in needed:
            wheels_to_install.append(str(whl))

# If no wheel dir, fall back to package names (for this prototype)
if not wheels_to_install:
    wheels_to_install = list(needed)

print(f"Installing {len(wheels_to_install)} packages...")

t0 = time.time()
subprocess.check_call([uv, "venv", venv_dir, "--python", python, "--quiet"])
t1 = time.time()
print(f"  venv created in {t1 - t0:.3f}s")

subprocess.check_call(
    [
        uv,
        "pip",
        "install",
        "--python",
        f"{venv_dir}/bin/python3",
        "--no-deps",
        "--link-mode=hardlink",
        "--quiet",
    ]
    + wheels_to_install
)
t2 = time.time()
print(f"  packages installed in {t2 - t1:.3f}s")
print(f"  total: {t2 - t0:.3f}s")
