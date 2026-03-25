"""Unit tests for staging.py — pure Python, no Bazel required.

Run with: python -m pytest pythonic/private/tests/
"""
import pathlib

from staging import stage_symlink_tree


class TestStageSymlinkTree:
    def test_vanilla_preserves_relative_paths(self, tmp_path):
        """Source files keep their path relative to pyproject.toml's parent."""
        pkg = tmp_path / "mypackage"
        (pkg / "src" / "mypackage").mkdir(parents=True)
        (pkg / "pyproject.toml").touch()
        (pkg / "src" / "mypackage" / "__init__.py").touch()
        (pkg / "src" / "mypackage" / "greeting.py").touch()

        staging = tmp_path / "staging"
        staging.mkdir()
        stage_symlink_tree(
            staging_dir=staging,
            pyproject=str(pkg / "pyproject.toml"),
            src_files=[
                str(pkg / "src" / "mypackage" / "__init__.py"),
                str(pkg / "src" / "mypackage" / "greeting.py"),
            ],
        )

        assert (staging / "pyproject.toml").exists()
        assert (staging / "src" / "mypackage" / "__init__.py").exists()
        assert (staging / "src" / "mypackage" / "greeting.py").exists()

    def test_assembled_tree_children_at_root(self, tmp_path):
        """TreeArtifact children land at staging root, not the tree directory.

        copy_to_directory produces a TreeArtifact named e.g. "assembled_tree"
        whose contents are the correctly shaped package (e.g. "assembled_pkg/").
        The build backend expects the package at the staging root, so we
        symlink the children — not the tree directory itself.
        """
        tree = tmp_path / "assembled_tree"
        (tree / "assembled_pkg").mkdir(parents=True)
        (tree / "assembled_pkg" / "__init__.py").touch()
        (tree / "assembled_pkg" / "mathlib.py").touch()

        pyproject = tmp_path / "pyproject.toml"
        pyproject.touch()

        staging = tmp_path / "staging"
        staging.mkdir()
        stage_symlink_tree(
            staging_dir=staging,
            pyproject=str(pyproject),
            src_files=[str(tree)],
        )

        assert (staging / "assembled_pkg" / "__init__.py").exists()
        assert (staging / "assembled_pkg" / "mathlib.py").exists()
        assert not (staging / "assembled_tree").exists()

    def test_src_prefix_strips_path(self, tmp_path):
        """src_prefix controls what gets stripped from individual file paths."""
        pkg = tmp_path / "mypackage"
        (pkg / "src" / "mypackage").mkdir(parents=True)
        (pkg / "pyproject.toml").touch()
        (pkg / "src" / "mypackage" / "__init__.py").touch()

        staging = tmp_path / "staging"
        staging.mkdir()
        stage_symlink_tree(
            staging_dir=staging,
            pyproject=str(pkg / "pyproject.toml"),
            src_files=[str(pkg / "src" / "mypackage" / "__init__.py")],
            src_prefix=str(pkg / "src"),
        )

        assert (staging / "mypackage" / "__init__.py").exists()
        # Without src_prefix this would be at src/mypackage/__init__.py.
        assert not (staging / "src").exists()
