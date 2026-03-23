def assert_greeting(actual: str, name: str) -> None:
    expected = f"Hello, {name}!"
    assert actual == expected, f"expected {expected!r}, got {actual!r}"
