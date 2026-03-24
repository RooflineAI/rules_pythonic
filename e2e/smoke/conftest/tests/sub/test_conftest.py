from mypkg import VALUE


def test_root_fixture(root_fixture):
    """Fixture from tests/conftest.py, included via parent filegroup."""
    assert root_fixture == "from_root_conftest"


def test_sub_fixture(sub_fixture):
    """Fixture from tests/sub/conftest.py, included directly."""
    assert sub_fixture == "from_sub_conftest"


def test_both(root_fixture, sub_fixture):
    """Both conftest levels compose correctly."""
    assert root_fixture == "from_root_conftest"
    assert sub_fixture == "from_sub_conftest"
    assert VALUE == 42
