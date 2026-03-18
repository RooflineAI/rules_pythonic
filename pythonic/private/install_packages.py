#!/usr/bin/env python3
"""Build-time action: install third-party wheels into a flat target directory.

Called by the pythonic_test rule as a Bazel action. Reads pyproject.toml files
to validate that declared dependencies are satisfiable, then installs all
provided wheels via `uv pip install --target`.

Requires Python >= 3.11 (for tomllib).
"""
import argparse
import pathlib
import re
import subprocess
import sys
import tomllib


def normalize_name(name: str) -> str:
    """Normalize a Python package name per PEP 503.

    Lowercases and collapses runs of [-_.] into a single hyphen.
    """
    return re.sub(r"[-_.]+", "-", name).lower()


def extract_dep_name(dep_spec: str) -> str:
    """Extract the package name from a PEP 508 dependency specifier.

    Examples: "torch>=2.1" -> "torch", "foo[bar]>=1.0" -> "foo"
    """
    for ch in "><=!;[":
        dep_spec = dep_spec.split(ch)[0]
    return dep_spec.strip()


def build_wheel_index(wheel_files: list[str]) -> dict[str, pathlib.Path]:
    """Build a mapping from normalized package name to wheel file path.

    Wheel filenames follow PEP 427:
    {name}-{version}(-{build})?-{python}-{abi}-{platform}.whl
    """
    index: dict[str, pathlib.Path] = {}
    for whl_path in wheel_files:
        whl = pathlib.Path(whl_path)
        if whl.exists() and whl.suffix == ".whl":
            dist_name = whl.name.split("-")[0]
            index[normalize_name(dist_name)] = whl
    return index


def collect_deps(
    pyproject_paths: list[str],
    extras: list[str],
) -> set[str]:
    """Collect normalized dependency names from pyproject.toml files.

    Returns the union of [project.dependencies] and requested
    [project.optional-dependencies] groups, deduplicated by normalized name.
    """
    needed: set[str] = set()

    for pp_path in pyproject_paths:
        pp = tomllib.loads(pathlib.Path(pp_path).read_text())
        project = pp.get("project", {})

        requires_python = project.get("requires-python")
        if requires_python:
            _check_python_version(requires_python, pp_path)

        for dep in project.get("dependencies", []):
            needed.add(normalize_name(extract_dep_name(dep)))

        opt_deps = project.get("optional-dependencies", {})
        for group in extras:
            for dep in opt_deps.get(group, []):
                needed.add(normalize_name(extract_dep_name(dep)))

    return needed


def _check_python_version(requires_python: str, pyproject_path: str) -> None:
    """Validate that the current Python satisfies requires-python."""
    py_version = f"{sys.version_info.major}.{sys.version_info.minor}"

    match = re.match(r">=\s*(\d+\.\d+)", requires_python)
    if match:
        required = match.group(1)
        if sys.version_info[:2] < tuple(int(x) for x in required.split(".")):
            print(
                f"ERROR: {pyproject_path} requires python >={required}, "
                f"but building with {py_version}",
                file=sys.stderr,
            )
            sys.exit(1)


def validate_deps(
    needed: set[str],
    wheel_index: dict[str, pathlib.Path],
    first_party_packages: set[str],
) -> list[str]:
    """Check that every declared dependency is either a wheel or first-party.

    Returns a list of missing dependency names (empty if all satisfied).
    """
    missing: list[str] = []
    for dep_name in sorted(needed):
        if dep_name not in wheel_index and dep_name not in first_party_packages:
            missing.append(dep_name)
    return missing


def verify_hardlinks(target_dir: pathlib.Path) -> None:
    """Warn if uv fell back to copies instead of hardlinks.

    uv silently copies when cache and output are on different filesystems.
    We sample a few files and check nlink > 1.
    """
    checked = 0
    for f in target_dir.rglob("*"):
        if f.is_file() and not f.is_symlink():
            if f.stat().st_nlink == 1 and f.stat().st_size > 4096:
                print(
                    "WARNING: hardlinks not working — files have nlink=1.\n"
                    "  UV_CACHE_DIR and output directory are likely on different\n"
                    "  filesystems, or the sandbox is blocking hardlinks.\n"
                    "  See: https://github.com/pythonicorg/rules_pythonic#hardlinks",
                    file=sys.stderr,
                )
                break
            checked += 1
            if checked >= 5:
                break


def install_packages(
    uv_bin: str,
    python_bin: str,
    output_dir: str,
    wheel_files: list[str],
    pyproject_paths: list[str],
    first_party_packages: list[str],
    extras: list[str],
) -> None:
    """Install third-party wheels into a flat target directory."""
    target_dir = pathlib.Path(output_dir)

    wheel_index = build_wheel_index(wheel_files)
    fp_normalized = {normalize_name(p) for p in first_party_packages}
    needed = collect_deps(pyproject_paths, extras)
    missing = validate_deps(needed, wheel_index, fp_normalized)

    if missing:
        for m in missing:
            print(
                f'ERROR: package "{m}" required by pyproject.toml but not found '
                f"in @pypi wheels and not a first-party dep.\n"
                f"       Add it to requirements.txt or to deps = [...] in BUILD.",
                file=sys.stderr,
            )
        sys.exit(1)

    target_dir.mkdir(parents=True, exist_ok=True)

    wheels_to_install = [w for w in wheel_files if w.endswith(".whl")]
    if wheels_to_install:
        subprocess.check_call([
            uv_bin, "pip", "install",
            "--target", str(target_dir),
            "--python", python_bin,
            # --no-deps: pip.parse already resolved the full transitive closure
            # --no-index: never contact PyPI; only use pre-downloaded wheels
            # --link-mode=hardlink: near-zero disk overhead when on same filesystem
            "--no-deps", "--no-index", "--link-mode=hardlink", "-q",
        ] + wheels_to_install)

        verify_hardlinks(target_dir)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Install third-party wheels into a flat directory for rules_pythonic.",
    )
    parser.add_argument("--uv-bin", required=True, help="Path to uv binary")
    parser.add_argument("--python-bin", required=True, help="Path to Python interpreter")
    parser.add_argument("--output-dir", required=True, help="Target directory for installed packages")
    parser.add_argument("--wheel-files", nargs="*", default=[], help="Paths to .whl files")
    parser.add_argument("--pyprojects", nargs="*", default=[], help="Paths to pyproject.toml files")
    parser.add_argument("--first-party-packages", nargs="*", default=[], help="Package names to skip (on PYTHONPATH)")
    parser.add_argument("--extras", nargs="*", default=[], help="Optional dependency groups to include")
    args = parser.parse_args()

    install_packages(
        uv_bin=args.uv_bin,
        python_bin=args.python_bin,
        output_dir=args.output_dir,
        wheel_files=args.wheel_files,
        pyproject_paths=args.pyprojects,
        first_party_packages=args.first_party_packages,
        extras=args.extras,
    )


if __name__ == "__main__":
    main()
