"""Shared utility: stage a symlink tree for pyproject.toml-based operations.

Used by both build_wheel.py (wheel building) and setup_devenv.py (editable
installs). Symlinks pyproject.toml and source files into a flat staging
directory so the PEP 517 build backend can find them.
"""

import pathlib


def stage_symlink_tree(
    staging_dir: pathlib.Path,
    pyproject: str,
    src_files: list[str],
    src_prefix: str | None = None,
) -> None:
    """Create a symlink tree mirroring the project layout around pyproject.toml.

    For vanilla packages, src files live under pyproject.toml's parent and
    their relative paths are preserved. For Bazel-assembled packages (e.g.
    copy_to_directory output), files live elsewhere — src_prefix tells us
    what to strip so the remaining path matches the build backend's config.

    Example (vanilla, src_prefix=None):
      pyproject: "mypackage/pyproject.toml"
      src file:  "mypackage/src/mypackage/greeting.py"
      staging:   <staging>/src/mypackage/greeting.py

    Example (assembled, src_prefix="bazel-out/.../assembled_tree"):
      pyproject: "assembled_pkg/pyproject.toml"
      src file:  "bazel-out/.../assembled_tree/assembled_pkg/__init__.py"
      staging:   <staging>/assembled_pkg/__init__.py
    """
    pyproject_path = pathlib.Path(pyproject)
    strip_dir = pathlib.Path(src_prefix) if src_prefix else pyproject_path.parent

    (staging_dir / "pyproject.toml").symlink_to(pyproject_path.resolve())

    # src_files can be individual files (from glob in vanilla packages) or
    # directories (TreeArtifacts from copy_to_directory in assembled packages).
    for src in src_files:
        src_path = pathlib.Path(src)

        if src_path.is_dir():
            # Symlink each child of the directory into the staging dir.
            # TreeArtifact names (e.g. "assembled_tree") don't match the
            # package names inside (e.g. "assembled_pkg/"), so we symlink
            # the contents rather than the directory itself.
            for child in src_path.iterdir():
                dest = staging_dir / child.name
                if not dest.exists():
                    dest.symlink_to(child.resolve())
        else:
            rel = src_path.relative_to(strip_dir)
            dest = staging_dir / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.symlink_to(src_path.resolve())
