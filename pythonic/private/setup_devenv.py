#!/usr/bin/env python3
"""Run-time action: create or update a Python venv for IDE use.

Called by `bazel run //:devenv`. Reads a JSON manifest produced at build time,
creates a venv via `uv venv`, installs third-party wheels, then editable-installs
first-party packages using the same staging mechanism as build_wheel.py.
"""

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

from staging import stage_symlink_tree


def _stage_wheels_dir(wheel_paths: list[pathlib.Path]) -> pathlib.Path:
    """Create a temp directory with symlinks to all wheel files.

    uv's --find-links needs a single directory of .whl files. The wheels
    live in scattered runfiles locations, so we symlink them into one place.
    This directory is only needed during installation and can be cleaned up.
    """
    staged = pathlib.Path(tempfile.mkdtemp(prefix="pythonic_devenv_wheels_"))
    for whl in wheel_paths:
        link = staged / whl.name
        if not link.exists():
            os.symlink(whl.resolve(), link)
    return staged


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Set up a Python dev environment for IDE use."
    )
    parser.add_argument(
        "--manifest", required=True, help="Path to JSON manifest from build time"
    )
    parser.add_argument("--uv-bin", required=True, help="Path to uv binary")
    parser.add_argument(
        "--python-bin", required=True, help="Path to Python interpreter"
    )
    parser.add_argument(
        "--workspace-dir",
        required=True,
        help="Workspace root ($BUILD_WORKSPACE_DIRECTORY)",
    )
    parser.add_argument(
        "--runfiles-dir", required=True, help="Runfiles root ($RUNFILES_DIR)"
    )
    args = parser.parse_args()

    manifest = json.loads(pathlib.Path(args.manifest).read_text())
    workspace = pathlib.Path(args.workspace_dir)
    runfiles = pathlib.Path(args.runfiles_dir)
    venv_dir = workspace / manifest["venv_path"]
    uv = args.uv_bin
    python = args.python_bin

    # Step 0: Create or update the venv.
    print(f"Creating venv at {venv_dir} ...")
    subprocess.check_call(
        [uv, "venv", "--python", python, "--allow-existing", str(venv_dir)]
    )

    venv_python = str(venv_dir / "bin" / "python")

    # Step 1: Install all third-party wheels (no resolution, just unpack).
    third_party_wheel_paths = [
        runfiles / rloc for rloc in manifest.get("third_party_wheels", [])
    ]
    if third_party_wheel_paths:
        print(f"Installing {len(third_party_wheel_paths)} third-party wheels ...")
        subprocess.check_call(
            [
                uv,
                "pip",
                "install",
                "--python",
                venv_python,
                "--no-deps",
                "--no-index",
                "--link-mode=hardlink",
                "-q",
            ]
            + [str(w) for w in third_party_wheel_paths]
        )

    # Step 2: Install first-party wheels. Each wheel dir is a Bazel
    # TreeArtifact containing exactly one .whl. We use --find-links with
    # the package name so uv picks the right file without globbing.
    first_party_wheels = manifest.get("first_party_wheels", [])
    for fp_whl in first_party_wheels:
        whl_dir = runfiles / fp_whl["dir"]
        print(f"Installing first-party wheel {fp_whl['name']} ...")
        subprocess.check_call(
            [
                uv,
                "pip",
                "install",
                "--python",
                venv_python,
                "--no-deps",
                "--no-index",
                "--find-links",
                str(whl_dir),
                "--link-mode=hardlink",
                "-q",
                fp_whl["name"],
            ]
        )

    # Step 3: Editable-install first-party source packages.
    # Each package is staged via stage_symlink_tree (same mechanism as wheel
    # building) then installed with uv pip install -e. A single uv call
    # installs all editables so uv can resolve cross-deps between them.
    editables = manifest.get("editables", [])
    extras = manifest.get("extras", [])
    constraints = manifest.get("constraints")

    if editables:
        cmd = [uv, "pip", "install", "--python", venv_python]

        # In hermetic mode, stage all third-party wheels into a flat temp
        # directory for --find-links. uv needs this to locate build backends
        # during editable installs and to validate dep completeness.
        if third_party_wheel_paths:
            wheels_dir = _stage_wheels_dir(third_party_wheel_paths)
            cmd += ["--no-index", "--find-links", str(wheels_dir)]

        if constraints:
            cmd += ["--constraint", str(workspace / constraints)]

        extras_suffix = ""
        if extras:
            extras_suffix = "[" + ",".join(extras) + "]"

        # Staging dirs must persist after install — editable installs reference
        # them via .pth files. We put them inside the venv so they survive
        # reboots and get cleaned up when the venv is recreated.
        staging_root = venv_dir / ".pythonic_staging"
        if staging_root.exists():
            shutil.rmtree(staging_root)
        staging_root.mkdir()

        for i, editable in enumerate(editables):
            staging_dir = staging_root / f"pkg_{i}"
            staging_dir.mkdir()
            stage_symlink_tree(
                staging_dir=staging_dir,
                pyproject=str(runfiles / editable["pyproject"]),
                src_files=[str(runfiles / s) for s in editable["srcs"]],
            )
            cmd.append("--editable")
            cmd.append(str(staging_dir) + extras_suffix)

        print(f"Installing {len(editables)} editable packages ...")
        subprocess.check_call(cmd)

    print(f"\nDone. Configure your IDE to use: {venv_dir / 'bin' / 'python'}")


if __name__ == "__main__":
    main()
