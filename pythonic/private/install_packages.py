#!/usr/bin/env python3
"""Build-time action: install third-party wheels into a flat target directory.

Called by the pythonic_test rule as a Bazel action. Reads pyproject.toml files
to validate that declared dependencies are satisfiable, then installs all
provided wheels via `uv pip install --target`.

Requires Python >= 3.11 (for tomllib).
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib

from staging import stage_symlink_tree, stage_wheels_dir

_HARDLINK_SAMPLE_SIZE = 5


def normalize_name(name: str) -> str:
    """Normalize a Python package name per PEP 503.

    Lowercases and collapses runs of [-_.] into a single hyphen.
    Example: "Foo-Bar" -> "foo-bar", "foo_bar" -> "foo-bar", "Foo.Bar" -> "foo-bar"
    """
    return re.sub(r"[-_.]+", "-", name).lower()


def extract_dep_name(dep_spec: str) -> str:
    """Extract the package name from a PEP 508 dependency specifier.

    Strips version constraints, extras markers, and environment markers.
    Extras like [bar] are optional install groups — they're handled separately
    via the --extras flag, not extracted as individual package names.

    Examples: "torch>=2.1" -> "torch", "foo[bar]>=1.0" -> "foo",
              "pkg ; python_version >= '3.11'" -> "pkg"
    """
    for ch in "><=!;[@":
        dep_spec = dep_spec.split(ch)[0]
    return dep_spec.strip()


def build_wheel_index(wheel_files: list[str]) -> dict[str, pathlib.Path]:
    """Build a mapping from normalized package name to wheel file path.

    Wheel filenames follow PEP 427:
    {name}-{version}(-{build})?-{python}-{abi}-{platform}.whl
    Example: "torch-2.10.0-cp311-cp311-linux_x86_64.whl" -> {"torch": Path(...)}
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

    Reads three sections from each pyproject.toml:

        [project]
        requires-python = ">=3.11"           # validated against current interpreter
        dependencies = ["torch>=2.1", "six"] # always collected

        [project.optional-dependencies]
        test = ["pytest>=7.0"]               # collected when "test" is in extras
        gpu = ["triton"]                     # collected when "gpu" is in extras

    Returns the union of all collected names, deduplicated by normalized name.
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
    """Validate that the current Python satisfies requires-python.

    Only handles the common >=X.Y pattern (e.g., ">=3.11"). More complex
    specifiers like ">=3.10,<3.13" are not yet supported.
    """
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
    declared_deps: set[str],
    available_wheels: dict[str, pathlib.Path],
    first_party_names: set[str],
) -> list[str]:
    """Check that every declared dependency is either a wheel or first-party.

    Returns a list of missing dependency names (empty if all satisfied).
    """
    missing: list[str] = []
    for dep_name in sorted(declared_deps):
        if dep_name not in available_wheels and dep_name not in first_party_names:
            missing.append(dep_name)
    return missing


def verify_hardlinks(
    target_dir: pathlib.Path, cache_dir: str, sample_size: int = _HARDLINK_SAMPLE_SIZE
) -> None:
    """Fail if uv fell back to copies instead of hardlinks.

    uv silently copies when cache and output are on different filesystems,
    or when the sandbox blocks link(2). We sample a few installed files and
    require nlink > 1 — a full copy means either a cross-device situation
    or a missing sandbox_writable_path for the uv cache.
    """
    checked = 0
    for f in target_dir.rglob("*"):
        if f.is_file() and not f.is_symlink():
            st = f.stat()
            if st.st_nlink == 1 and st.st_size > 4096:
                print(
                    "ERROR: hardlinks not working — installed files have nlink=1.\n"
                    f"  UV_CACHE_DIR={cache_dir}\n"
                    f"  output_dir={target_dir}\n\n"
                    "  Ensure both directories are on the same filesystem and that\n"
                    "  the sandbox can access the cache. Add to your .bazelrc:\n\n"
                    f"    build --sandbox_writable_path={cache_dir}\n",
                    file=sys.stderr,
                )
                sys.exit(1)
            checked += 1
            if checked >= sample_size:
                break


def _require_uv_cache_dir() -> str:
    """Return UV_CACHE_DIR from the environment, or fail with setup instructions."""
    cache_dir = os.environ.get("UV_CACHE_DIR")
    if cache_dir:
        return cache_dir

    print(
        "ERROR: UV_CACHE_DIR not set. PythonicInstall needs a writable uv cache\n"
        "on the same filesystem as your Bazel output base for hardlinks to work.\n\n"
        "Add to your .bazelrc:\n\n"
        "  build --action_env=UV_CACHE_DIR=/path/to/uv/cache\n"
        "  build --sandbox_writable_path=/path/to/uv/cache\n\n"
        "Common default paths:\n"
        "  macOS:  /Users/<you>/Library/Caches/uv\n"
        "  Linux:  /home/<you>/.cache/uv\n",
        file=sys.stderr,
    )
    sys.exit(1)


def resolve_wheels(
    wheel_files: list[str],
    pyproject_paths: list[str],
    first_party_packages: list[str],
    first_party_wheel_dirs: list[str],
    extras: list[str],
) -> list[str]:
    """Validate deps and return the full list of .whl paths to install.

    Raises:
        SystemExit: If any declared dependency is unsatisfiable, or if a
            first-party wheel directory contains no .whl files.
    """
    # Wheel filenames include the version from pyproject.toml, so they aren't
    # known at Bazel analysis time. Glob at execution time.
    fp_wheels: list[str] = []
    for d in first_party_wheel_dirs:
        found = list(pathlib.Path(d).glob("*.whl"))
        if not found:
            print(
                f"ERROR: first-party wheel directory contains no .whl files:"
                f" {d}\n"
                f"       The upstream .wheel target may have failed to"
                f" produce output.\n"
                f"       Try: bazel build <package>.wheel",
                file=sys.stderr,
            )
            sys.exit(1)
        fp_wheels.extend(str(w) for w in found)

    available_wheels = build_wheel_index(wheel_files + fp_wheels)
    first_party_names = {normalize_name(p) for p in first_party_packages}
    declared_deps = collect_deps(pyproject_paths, extras)
    missing = validate_deps(declared_deps, available_wheels, first_party_names)

    if missing:
        for m in missing:
            print(
                f'ERROR: package "{m}" required by pyproject.toml but not found '
                f"in @pypi wheels and not a first-party dep.\n"
                f"       Add it to requirements.txt or to deps = [...] in BUILD.",
                file=sys.stderr,
            )
        sys.exit(1)

    wheels_to_install = [w for w in wheel_files if w.endswith(".whl")]
    wheels_to_install.extend(fp_wheels)
    return wheels_to_install


def install_packages(
    uv_bin: str,
    python_bin: str,
    output_dir: str,
    wheel_files: list[str],
    pyproject_paths: list[str],
    first_party_packages: list[str],
    first_party_wheel_dirs: list[str],
    extras: list[str],
    install_all: bool = False,
    source_packages: list[dict] | None = None,
) -> None:
    """Install third-party and first-party wheels into a flat target directory.

    Two modes:
    - install_all=True: install every provided wheel with --no-deps (legacy).
    - install_all=False (default): resolve only the transitive closure of
      declared deps from the available wheels via uv.
    """
    target_dir = pathlib.Path(output_dir)
    cache_dir = _require_uv_cache_dir()

    # Validates deps and globs first-party wheel dirs.
    wheels_to_install = resolve_wheels(
        wheel_files,
        pyproject_paths,
        first_party_packages,
        first_party_wheel_dirs,
        extras,
    )

    target_dir.mkdir(parents=True, exist_ok=True)
    if not wheels_to_install:
        # Still generate dist-info for source packages even with no wheels.
        generate_source_distinfo(
            uv_bin=uv_bin,
            python_bin=python_bin,
            output_dir=target_dir,
            source_packages=source_packages or [],
            wheel_files=wheel_files,
        )
        return

    uv_base = [
        uv_bin,
        "pip",
        "install",
        "--cache-dir",
        cache_dir,
        "--target",
        str(target_dir),
        "--python",
        python_bin,
        "--no-index",
        "--link-mode=hardlink",
        "-q",
    ]

    if install_all:
        subprocess.check_call(uv_base + ["--no-deps"] + wheels_to_install)
        verify_hardlinks(target_dir, cache_dir)
        return

    # Filtered mode: split into first-party wheels (install directly) and
    # third-party (let uv resolve transitively from package names).
    fp_wheel_files: set[str] = set()
    for d in first_party_wheel_dirs:
        for w in pathlib.Path(d).glob("*.whl"):
            fp_wheel_files.add(str(w))

    tp_wheel_files = [w for w in wheels_to_install if w not in fp_wheel_files]

    if fp_wheel_files:
        subprocess.check_call(uv_base + ["--no-deps"] + sorted(fp_wheel_files))

    first_party_names = {normalize_name(p) for p in first_party_packages}
    package_names = sorted(collect_deps(pyproject_paths, extras) - first_party_names)

    if package_names:
        find_links_dir = stage_wheels_dir([pathlib.Path(w) for w in tp_wheel_files])
        subprocess.check_call(
            uv_base + ["--find-links", str(find_links_dir)] + package_names
        )

    verify_hardlinks(target_dir, cache_dir)

    # Generate dist-info for source deps so importlib.metadata can discover
    # entry points and version info. Runs after wheel installation so the
    # build backend is available via --find-links.
    generate_source_distinfo(
        uv_bin=uv_bin,
        python_bin=python_bin,
        output_dir=target_dir,
        source_packages=source_packages or [],
        wheel_files=wheel_files,
    )


_PYTHONIC_NOTICE = """\
This dist-info was generated by rules_pythonic for metadata discovery only.

The source files for this package are NOT installed — they are resolved
via PYTHONPATH at runtime. RECORD, direct_url.json, and other path-
dependent files have been removed because they referenced sandbox paths
that do not exist at runtime.

Package source is available via the pythonic_package Bazel target.
"""

_DISTINFO_KEEP = {"METADATA", "entry_points.txt"}


def generate_source_distinfo(
    uv_bin: str,
    python_bin: str,
    output_dir: pathlib.Path,
    source_packages: list[dict],
    wheel_files: list[str],
) -> None:
    """Generate dist-info for first-party source packages via editable install.

    For each source package, stages the source tree, runs uv pip install -e
    into a temp directory, then copies only METADATA and entry_points.txt
    into the output TreeArtifact. This gives importlib.metadata access to
    entry points and version info without changing the PYTHONPATH-based
    import resolution.
    """
    if not source_packages:
        return

    cache_dir = os.environ.get("UV_CACHE_DIR", "")

    # Stage all available wheels for --find-links so the build backend
    # (hatchling etc.) is available without PyPI access.
    find_links_dir = stage_wheels_dir(
        [pathlib.Path(w) for w in wheel_files if w.endswith(".whl")]
    )

    for sp in source_packages:
        staging_dir = pathlib.Path(tempfile.mkdtemp(prefix="pythonic_stage_"))
        stage_symlink_tree(
            staging_dir=staging_dir,
            pyproject=sp["pyproject"],
            src_files=sp["srcs"],
        )

        temp_target = pathlib.Path(tempfile.mkdtemp(prefix="pythonic_distinfo_"))
        subprocess.check_call(
            [
                uv_bin,
                "pip",
                "install",
                "--editable",
                str(staging_dir),
                "--target",
                str(temp_target),
                "--python",
                python_bin,
                "--no-index",
                "--find-links",
                str(find_links_dir),
                "--no-deps",
                "--cache-dir",
                cache_dir,
                "-q",
            ]
        )

        # Copy only METADATA and entry_points.txt from the dist-info.
        for dist_info in temp_target.glob("*.dist-info"):
            dest = output_dir / dist_info.name
            dest.mkdir(exist_ok=True)
            for keep_file in _DISTINFO_KEEP:
                src = dist_info / keep_file
                if src.exists():
                    shutil.copy2(src, dest / keep_file)
            (dest / "PYTHONIC_NOTICE").write_text(_PYTHONIC_NOTICE)

        shutil.rmtree(staging_dir, ignore_errors=True)
        shutil.rmtree(temp_target, ignore_errors=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Install third-party wheels into a flat directory for rules_pythonic."
        ),
    )
    parser.add_argument("--uv-bin", required=True, help="Path to uv binary")
    parser.add_argument(
        "--python-bin", required=True, help="Path to Python interpreter"
    )
    parser.add_argument(
        "--output-dir", required=True, help="Target directory for installed packages"
    )
    parser.add_argument(
        "--wheel-files", nargs="*", default=[], help="Paths to .whl files"
    )
    parser.add_argument(
        "--pyprojects", nargs="*", default=[], help="Paths to pyproject.toml files"
    )
    parser.add_argument(
        "--first-party-packages",
        nargs="*",
        default=[],
        help="Package names to skip (on PYTHONPATH)",
    )
    parser.add_argument(
        "--first-party-wheel-dirs",
        action="append",
        default=[],
        help="Directory containing a first-party .whl file to install",
    )
    parser.add_argument(
        "--extras", nargs="*", default=[], help="Optional dependency groups to include"
    )
    parser.add_argument(
        "--install-all",
        action="store_true",
        help="Install all provided wheels instead of resolving the minimal set",
    )
    parser.add_argument(
        "--source-package",
        action="append",
        default=[],
        help="JSON object with pyproject and srcs paths for dist-info generation",
    )
    args = parser.parse_args()

    install_packages(
        uv_bin=args.uv_bin,
        python_bin=args.python_bin,
        output_dir=args.output_dir,
        wheel_files=args.wheel_files,
        pyproject_paths=args.pyprojects,
        first_party_packages=args.first_party_packages,
        first_party_wheel_dirs=args.first_party_wheel_dirs,
        extras=args.extras,
        install_all=args.install_all,
        source_packages=[json.loads(sp) for sp in args.source_package],
    )


if __name__ == "__main__":
    main()
