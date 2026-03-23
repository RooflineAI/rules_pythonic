from mypackage.greeting import hello
from testlib import assert_greeting


def test_hello_via_helper():
    assert_greeting(hello("Helpers"), "Helpers")
