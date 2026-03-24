import importlib.util

import pytest


@pytest.mark.xfail(
    reason="install_packages.py does not yet filter wheels to declared deps",
    strict=True,
)
def test_analysis_extra_not_importable():
    """Without extras=['analysis'], tomli should not be installed.
    tomli is not a transitive dep of anything in base deps or [test],
    so it only appears when the analysis group is explicitly requested."""
    assert importlib.util.find_spec("tomli") is None, (
        "tomli was installed without extras=['analysis']"
    )
