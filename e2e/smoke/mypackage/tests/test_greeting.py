import importlib.metadata

from mypackage.greeting import hello


def test_hello():
    assert hello("World") == "Hello, World!"


def test_third_party_metadata():
    """Verify importlib.metadata works — proves .dist-info is intact."""
    version = importlib.metadata.version("six")
    assert version == "1.17.0"


def test_entry_point_discovery():
    """Verify entry points are discoverable for source deps via dist-info."""
    eps = importlib.metadata.entry_points(group="mypackage.plugins")
    names = {ep.name for ep in eps}
    assert "greeter" in names, f"greeter entry point not found, got: {names}"

    ep = next(ep for ep in eps if ep.name == "greeter")
    fn = ep.load()
    assert fn("World") == "Hello, World!"


def test_source_dep_version_metadata():
    """Verify importlib.metadata.version works for source deps."""
    version = importlib.metadata.version("mypackage")
    assert version == "0.1.0"
