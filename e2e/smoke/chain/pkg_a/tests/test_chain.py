from pkg_a import RESULT
from pkg_b import COMBINED
from pkg_c import VALUE


def test_transitive_imports():
    assert VALUE == "from_c"
    assert COMBINED == "b_saw_from_c"
    assert RESULT == "a_saw_b_saw_from_c"
