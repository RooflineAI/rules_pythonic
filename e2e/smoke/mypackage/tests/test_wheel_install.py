import importlib.metadata
import importlib.util
import sys

from mypackage.greeting import hello


def test_hello_via_wheel():
    assert hello("World") == "Hello, World!"


def test_wheel_metadata_present():
    """importlib.metadata only works if the .whl was unpacked with .dist-info.
    This fails when mypackage is on PYTHONPATH as raw source."""
    version = importlib.metadata.version("mypackage")
    assert version == "0.1.0"


def test_source_root_not_on_path():
    """The wheel dep's src_root should be excluded from PYTHONPATH."""
    assert not any("mypackage/src" in p for p in sys.path), (
        f"mypackage src_root leaked onto sys.path: {sys.path}"
    )
