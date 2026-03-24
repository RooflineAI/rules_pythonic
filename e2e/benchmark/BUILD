load("@pypi//:requirements.bzl", "all_whl_requirements", "requirement")
load("@rules_pythonic//pythonic:defs.bzl", "pythonic_package", "pythonic_test")
load("@aspect_rules_py//py:defs.bzl", "py_library", "py_test")

filegroup(
    name = "all_wheels",
    srcs = all_whl_requirements,
    visibility = ["//visibility:public"],
)

# --- rules_pythonic ---

pythonic_package(
    name = "mypackage_pythonic",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
)

pythonic_test(
    name = "test_pythonic",
    srcs = ["tests/test_model.py"],
    deps = [":mypackage_pythonic"],
)

# --- rules_py ---

py_library(
    name = "mypackage_rules_py",
    srcs = glob(["src/**/*.py"]),
    imports = ["src"],
    deps = [requirement("torch")],
)

py_test(
    name = "test_rules_py",
    srcs = ["tests/test_model.py"],
    imports = ["src"],
    pytest_main = True,
    deps = [
        ":mypackage_rules_py",
        requirement("pytest"),
    ],
)

# --- trivial tests (isolate infrastructure overhead) ---

pythonic_test(
    name = "test_trivial_pythonic",
    srcs = ["tests/test_trivial.py"],
    deps = [":mypackage_pythonic"],
)

py_test(
    name = "test_trivial_rules_py",
    srcs = ["tests/test_trivial.py"],
    imports = ["src"],
    pytest_main = True,
    deps = [
        ":mypackage_rules_py",
        requirement("pytest"),
    ],
)
