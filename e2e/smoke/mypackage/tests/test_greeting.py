import importlib.metadata

from mypackage.greeting import hello


def test_hello():
    assert hello("World") == "Hello, World!"


def test_third_party_metadata():
    """Verify importlib.metadata works — proves .dist-info is intact."""
    version = importlib.metadata.version("six")
    assert version == "1.17.0"


def test_sys_path():
    """Verify PYTHONPATH has source roots and site-packages."""
    import sys

    assert any("mypackage/src" in p for p in sys.path), (
        f"src root not on sys.path: {sys.path}"
    )
    assert any("site-packages" in p for p in sys.path), (
        f"site-packages not on sys.path: {sys.path}"
    )
