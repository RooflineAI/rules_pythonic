import six


def hello(name: str) -> str:
    if six.PY3:
        return f"Hello, {name}!"
    return "Hello, %s!" % name


if __name__ == "__main__":
    print(hello("Binary"))
