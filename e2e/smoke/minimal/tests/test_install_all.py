"""Verify that install_all_wheels=True installs everything from requirements.txt.

Same minimal package with no third-party deps, but install_all_wheels=True
means the full requirement set is available — including packages not in
minimal's dep closure.
"""

import importlib.util

from minimal import greet


def test_greet():
    assert greet() == "hello from minimal"


def test_all_wheels_available():
    """six and tomli are in requirements.txt and should be installed."""
    assert importlib.util.find_spec("six") is not None, "six should be installed"
    assert importlib.util.find_spec("tomli") is not None, "tomli should be installed"
