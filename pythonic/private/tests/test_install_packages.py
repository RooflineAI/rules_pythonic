"""Unit tests for install_packages.py — pure Python, no Bazel required.

Run with: python -m pytest pythonic/private/tests/
"""
import pathlib

import pytest

from install_packages import (
    build_wheel_index,
    collect_deps,
    extract_dep_name,
    normalize_name,
    validate_deps,
    verify_hardlinks,
    _check_python_version,
)


# --- normalize_name (PEP 503) ---

class TestNormalizeName:
    def test_hyphen(self):
        assert normalize_name("Foo-Bar") == "foo-bar"

    def test_underscore(self):
        assert normalize_name("foo_bar") == "foo-bar"

    def test_dot(self):
        assert normalize_name("Foo.Bar") == "foo-bar"

    def test_consecutive_separators(self):
        assert normalize_name("FOO---bar") == "foo-bar"

    def test_mixed_separators(self):
        assert normalize_name("Foo-_.-Bar") == "foo-bar"

    def test_noop(self):
        assert normalize_name("foo") == "foo"

    def test_nvidia_style(self):
        assert normalize_name("nvidia_cudnn_cu12") == "nvidia-cudnn-cu12"


# --- extract_dep_name (PEP 508) ---

class TestExtractDepName:
    def test_bare_name(self):
        assert extract_dep_name("six") == "six"

    def test_version_ge(self):
        assert extract_dep_name("torch>=2.1") == "torch"

    def test_extras_bracket(self):
        assert extract_dep_name("foo[bar]>=1.0") == "foo"

    def test_environment_marker(self):
        assert extract_dep_name("pkg ; python_version >= '3.11'") == "pkg"

    def test_multiple_constraints(self):
        assert extract_dep_name("numpy>=1.21,<2.0") == "numpy"

    def test_not_equal(self):
        assert extract_dep_name("setuptools!=50.0") == "setuptools"

    def test_exact_pin(self):
        assert extract_dep_name("foo==1.0") == "foo"

    def test_url_dep(self):
        assert extract_dep_name("pkg @ https://example.com/pkg.tar.gz") == "pkg"


# --- build_wheel_index (PEP 427 filenames) ---

class TestBuildWheelIndex:
    def test_indexes_and_normalizes(self, tmp_path):
        (tmp_path / "six-1.17.0-py3-none-any.whl").touch()
        (tmp_path / "nvidia_cudnn_cu12-9.1.0-py3-none-manylinux1_x86_64.whl").touch()

        index = build_wheel_index([
            str(tmp_path / "six-1.17.0-py3-none-any.whl"),
            str(tmp_path / "nvidia_cudnn_cu12-9.1.0-py3-none-manylinux1_x86_64.whl"),
        ])
        assert "six" in index
        assert "nvidia-cudnn-cu12" in index

    def test_build_tag_in_filename(self, tmp_path):
        (tmp_path / "foo-1.0-1-py3-none-any.whl").touch()

        index = build_wheel_index([str(tmp_path / "foo-1.0-1-py3-none-any.whl")])
        assert "foo" in index

    def test_skips_nonexistent_and_non_whl(self, tmp_path):
        (tmp_path / "metadata.txt").touch()

        index = build_wheel_index([
            "/nonexistent/foo-1.0-py3-none-any.whl",
            str(tmp_path / "metadata.txt"),
        ])
        assert len(index) == 0


# --- collect_deps (pyproject.toml parsing + extras) ---

def _write_pyproject(path, content):
    import textwrap
    path.write_text(textwrap.dedent(content))
    return str(path)


class TestCollectDeps:
    def test_basic_dependencies(self, tmp_path):
        pp = _write_pyproject(tmp_path / "pyproject.toml", """\
            [project]
            name = "mypackage"
            dependencies = ["six", "torch>=2.1"]
        """)
        assert collect_deps([pp], extras=[]) == {"six", "torch"}

    def test_extras_selection(self, tmp_path):
        pp = _write_pyproject(tmp_path / "pyproject.toml", """\
            [project]
            name = "mypackage"
            dependencies = ["six"]
            [project.optional-dependencies]
            test = ["pytest>=7.0"]
            gpu = ["triton"]
        """)
        assert collect_deps([pp], extras=["test"]) == {"six", "pytest"}
        assert collect_deps([pp], extras=["test", "gpu"]) == {"six", "pytest", "triton"}

    def test_missing_extras_group_is_silent(self, tmp_path):
        pp = _write_pyproject(tmp_path / "pyproject.toml", """\
            [project]
            name = "mypackage"
            dependencies = ["six"]
        """)
        assert collect_deps([pp], extras=["nonexistent"]) == {"six"}

    def test_union_across_multiple_pyprojects(self, tmp_path):
        pp1 = _write_pyproject(tmp_path / "a.toml", """\
            [project]
            name = "pkg-a"
            dependencies = ["six"]
        """)
        pp2 = _write_pyproject(tmp_path / "b.toml", """\
            [project]
            name = "pkg-b"
            dependencies = ["torch"]
        """)
        assert collect_deps([pp1, pp2], extras=[]) == {"six", "torch"}

    def test_dedup_across_pyprojects(self, tmp_path):
        pp1 = _write_pyproject(tmp_path / "a.toml", """\
            [project]
            name = "pkg-a"
            dependencies = ["six"]
        """)
        pp2 = _write_pyproject(tmp_path / "b.toml", """\
            [project]
            name = "pkg-b"
            dependencies = ["six"]
        """)
        assert collect_deps([pp1, pp2], extras=[]) == {"six"}

    def test_requires_python_failure_propagates(self, tmp_path):
        pp = _write_pyproject(tmp_path / "pyproject.toml", """\
            [project]
            name = "mypackage"
            requires-python = ">=99.0"
            dependencies = ["six"]
        """)
        with pytest.raises(SystemExit):
            collect_deps([pp], extras=[])


# --- validate_deps ---

class TestValidateDeps:
    def test_all_satisfied_by_wheels(self):
        assert validate_deps(
            {"six", "torch"},
            {"six": pathlib.Path("s.whl"), "torch": pathlib.Path("t.whl")},
            set(),
        ) == []

    def test_first_party_satisfies(self):
        assert validate_deps(
            {"six", "mypackage"},
            {"six": pathlib.Path("s.whl")},
            {"mypackage"},
        ) == []

    def test_reports_missing(self):
        assert validate_deps(
            {"six", "nonexistent"},
            {"six": pathlib.Path("s.whl")},
            set(),
        ) == ["nonexistent"]


# --- _check_python_version ---

class TestCheckPythonVersion:
    def test_current_python_satisfies(self):
        _check_python_version(">=3.11", "test.toml")

    def test_impossible_version_fails(self):
        with pytest.raises(SystemExit):
            _check_python_version(">=99.0", "test.toml")

    def test_unrecognized_pattern_is_ignored(self):
        _check_python_version("~=3.11", "test.toml")


# --- verify_hardlinks ---

class TestVerifyHardlinks:
    def test_passes_when_hardlinked(self, tmp_path):
        f1 = tmp_path / "original.dat"
        f1.write_bytes(b"x" * 8192)
        (tmp_path / "link.dat").hardlink_to(f1)

        verify_hardlinks(tmp_path, "/fake/cache")

    def test_fails_on_copies(self, tmp_path):
        (tmp_path / "copied.dat").write_bytes(b"x" * 8192)

        with pytest.raises(SystemExit):
            verify_hardlinks(tmp_path, "/fake/cache")

    def test_ignores_small_files(self, tmp_path):
        (tmp_path / "tiny.dat").write_bytes(b"x" * 100)

        verify_hardlinks(tmp_path, "/fake/cache")

    def test_skips_symlinks(self, tmp_path):
        target = tmp_path / "real.dat"
        target.write_bytes(b"x" * 8192)
        (tmp_path / "link.dat").symlink_to(target)
        # Remove the real file so only the symlink remains (dangling is fine,
        # rglob won't yield it). Instead, keep it but ensure symlink is skipped.
        # The real file has nlink=1 but verify_hardlinks should only check
        # non-symlink files. With one real file at nlink=1, this SHOULD fail.
        # But if the only large file were a symlink, it should pass.
        #
        # Set up: one symlink (skipped) + one small real file (below threshold).
        target.unlink()
        (tmp_path / "tiny.dat").write_bytes(b"x" * 100)
        (tmp_path / "sym.dat").symlink_to(tmp_path / "tiny.dat")

        verify_hardlinks(tmp_path, "/fake/cache")

    def test_empty_dir(self, tmp_path):
        verify_hardlinks(tmp_path, "/fake/cache")
