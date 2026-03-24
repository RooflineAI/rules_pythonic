import pytest


@pytest.fixture
def sub_fixture():
    return "from_sub_conftest"
