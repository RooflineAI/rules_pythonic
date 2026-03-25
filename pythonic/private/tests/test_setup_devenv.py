"""Unit tests for setup_devenv.py — pure Python, no Bazel required.

Run with: python -m pytest pythonic/private/tests/
"""

from setup_devenv import _stage_wheels_dir


# --- _stage_wheels_dir ---

class TestStageWheelsDir:
    def test_creates_flat_symlink_directory(self, tmp_path):
        """All wheel files are symlinked into a single flat directory."""
        # Simulate scattered runfiles layout: wheels in different directories.
        dir_a = tmp_path / "pypi" / "six"
        dir_a.mkdir(parents=True)
        whl_a = dir_a / "six-1.17.0-py3-none-any.whl"
        whl_a.touch()

        dir_b = tmp_path / "pypi" / "pytest"
        dir_b.mkdir(parents=True)
        whl_b = dir_b / "pytest-8.3.4-py3-none-any.whl"
        whl_b.touch()

        staged = _stage_wheels_dir([whl_a, whl_b])

        assert (staged / "six-1.17.0-py3-none-any.whl").is_symlink()
        assert (staged / "pytest-8.3.4-py3-none-any.whl").is_symlink()
        assert (staged / "six-1.17.0-py3-none-any.whl").resolve() == whl_a.resolve()
        assert (staged / "pytest-8.3.4-py3-none-any.whl").resolve() == whl_b.resolve()

    def test_deduplicates_by_filename(self, tmp_path):
        """If two paths have the same basename, only one symlink is created."""
        dir_a = tmp_path / "a"
        dir_a.mkdir()
        whl_a = dir_a / "six-1.17.0-py3-none-any.whl"
        whl_a.touch()

        dir_b = tmp_path / "b"
        dir_b.mkdir()
        whl_b = dir_b / "six-1.17.0-py3-none-any.whl"
        whl_b.touch()

        staged = _stage_wheels_dir([whl_a, whl_b])

        links = list(staged.iterdir())
        assert len(links) == 1
        assert links[0].name == "six-1.17.0-py3-none-any.whl"

    def test_empty_list(self):
        """Empty input produces an empty directory."""
        staged = _stage_wheels_dir([])
        assert list(staged.iterdir()) == []
