import pytest


@pytest.fixture
def root_fixture():
    return "from_root_conftest"
