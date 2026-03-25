#!/usr/bin/env python3
"""Build-time action: build a wheel via uv build with a staged symlink tree.

Called by the pythonic_package rule's .wheel sub-target. Stages source files
and pyproject.toml into a temporary directory via symlinks, then delegates
to `uv build --wheel` which invokes the PEP 517 build backend declared in
the pyproject.toml.

"""
import argparse
import pathlib
import subprocess

from staging import stage_symlink_tree


def build_wheel(
    uv_bin: str,
    python_bin: str,
    staging_dir: pathlib.Path,
    output_dir: str,
    wheel_dirs: list[str],
) -> None:
    """Run uv build --wheel in the staging directory."""
    # Resolve all paths before cwd changes to the staging directory.
    uv_bin = str(pathlib.Path(uv_bin).resolve())
    python_bin = str(pathlib.Path(python_bin).resolve())
    output_dir = str(pathlib.Path(output_dir).resolve())

    cmd = [
        uv_bin, "build", "--wheel",
        "--python", python_bin,
        "--out-dir", output_dir,
        "--no-index",
    ]
    for d in wheel_dirs:
        cmd.extend(["--find-links", str(pathlib.Path(d).resolve())])

    subprocess.check_call(cmd, cwd=str(staging_dir))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build a Python wheel via uv build with a staged symlink tree.",
    )
    parser.add_argument("--uv-bin", required=True)
    parser.add_argument("--python-bin", required=True)
    parser.add_argument("--pyproject", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--src-files", nargs="*", default=[])
    parser.add_argument("--src-prefix", default=None,
                        help="Prefix to strip from src file paths. "
                             "Defaults to pyproject.toml's parent directory.")
    parser.add_argument("--wheel-dirs", nargs="*", default=[])
    args = parser.parse_args()

    staging_dir = pathlib.Path(args.output_dir + ".staging")
    staging_dir.mkdir(parents=True)

    stage_symlink_tree(
        staging_dir=staging_dir,
        pyproject=args.pyproject,
        src_files=args.src_files,
        src_prefix=args.src_prefix,
    )
    build_wheel(
        uv_bin=args.uv_bin,
        python_bin=args.python_bin,
        staging_dir=staging_dir,
        output_dir=args.output_dir,
        wheel_dirs=args.wheel_dirs,
    )


if __name__ == "__main__":
    main()
