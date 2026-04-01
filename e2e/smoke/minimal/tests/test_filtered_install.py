"""Verify that filtered install only includes declared transitive deps.

minimal declares zero third-party dependencies (only pytest via [test] extras).
With filtered install, packages like six and tomli — present in the global
requirements.txt but not in minimal's dep closure — must not be installed.
"""

import importlib.util

from minimal import greet


def test_greet():
    assert greet() == "hello from minimal"


def test_undeclared_packages_not_installed():
    """six and tomli are in requirements.txt but not in minimal's dep graph."""
    assert importlib.util.find_spec("six") is None, "six should not be installed"
    assert importlib.util.find_spec("tomli") is None, "tomli should not be installed"
