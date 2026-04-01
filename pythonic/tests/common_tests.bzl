"Unit tests for pythonic/private/common.bzl helper functions."

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//pythonic/private:common.bzl", "build_env_exports", "build_pythonpath", "rlocation_path")

# Lightweight stubs — these functions only read .workspace_name and
# .short_path, so full Bazel objects aren't needed.

def _mock_ctx(workspace_name):
    return struct(workspace_name = workspace_name)

def _mock_file(short_path):
    return struct(short_path = short_path)

# --- rlocation_path ---
# Load-bearing for every runfiles resolution. The ../  strip for external
# repos is a convention shared with rules_python and rules_cc; getting the
# slice index wrong silently breaks all tool resolution.

def _rlocation_workspace_file_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "myworkspace/pkg/foo.py",
        rlocation_path(_mock_ctx("myworkspace"), _mock_file("pkg/foo.py")),
    )
    return unittest.end(env)

_rlocation_workspace_file_test = unittest.make(_rlocation_workspace_file_test_impl)

def _rlocation_external_repo_test_impl(ctx):
    """External repo short_paths start with '../' — the prefix must be stripped.

    A one-off error in the slice index (e.g. [2:] instead of [3:]) would
    produce '/rules_python...' which silently fails at runfiles lookup.
    """
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "rules_python++python+python_3_11/bin/python3",
        rlocation_path(
            _mock_ctx("myworkspace"),
            _mock_file("../rules_python++python+python_3_11/bin/python3"),
        ),
    )
    return unittest.end(env)

_rlocation_external_repo_test = unittest.make(_rlocation_external_repo_test_impl)

# --- build_pythonpath ---
# Feeds directly into every launcher template. The trailing colon lets
# the template concatenate PACKAGES_DIR without a leading colon when
# first-party entries are present.

def _pythonpath_basic_test_impl(ctx):
    env = unittest.begin(ctx)
    result = build_pythonpath(_mock_ctx("ws"), ["pkg/src", "lib/src"])
    asserts.equals(
        env,
        '"$(rlocation ws/pkg/src)":"$(rlocation ws/lib/src)":',
        result,
    )
    return unittest.end(env)

_pythonpath_basic_test = unittest.make(_pythonpath_basic_test_impl)

def _pythonpath_empty_test_impl(ctx):
    """Empty source roots must produce empty string, not a bare colon."""
    env = unittest.begin(ctx)
    asserts.equals(env, "", build_pythonpath(_mock_ctx("ws"), []))
    return unittest.end(env)

_pythonpath_empty_test = unittest.make(_pythonpath_empty_test_impl)

def _pythonpath_single_entry_test_impl(ctx):
    """Single entry still gets trailing colon for PACKAGES_DIR concatenation."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        '"$(rlocation ws/src)":',
        build_pythonpath(_mock_ctx("ws"), ["src"]),
    )
    return unittest.end(env)

_pythonpath_single_entry_test = unittest.make(_pythonpath_single_entry_test_impl)

# --- build_env_exports ---
# Produces shell export lines from action_env values. Users control these
# values via --action_env in .bazelrc, so shell metacharacters in paths
# (dollar, backtick, quotes, backslash) must be escaped correctly.

def _env_exports_dollar_test_impl(ctx):
    """Dollar sign — unescaped causes shell variable expansion.

    Triggered by: --action_env=UV_CACHE_DIR=$HOME/.cache/uv
    """
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        'export UV_CACHE_DIR="\\$HOME/.cache/uv"\n',
        build_env_exports({"UV_CACHE_DIR": "$HOME/.cache/uv"}),
    )
    return unittest.end(env)

_env_exports_dollar_test = unittest.make(_env_exports_dollar_test_impl)

def _env_exports_backtick_test_impl(ctx):
    """Backtick — unescaped causes command substitution."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        'export K="\\`id\\`"\n',
        build_env_exports({"K": "`id`"}),
    )
    return unittest.end(env)

_env_exports_backtick_test = unittest.make(_env_exports_backtick_test_impl)

def _env_exports_double_quote_test_impl(ctx):
    """Double quote — unescaped breaks out of the quoting."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        'export K="say \\"hello\\""\n',
        build_env_exports({"K": 'say "hello"'}),
    )
    return unittest.end(env)

_env_exports_double_quote_test = unittest.make(_env_exports_double_quote_test_impl)

def _env_exports_backslash_test_impl(ctx):
    """Backslash must be escaped first to avoid double-escaping others."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        'export P="C:\\\\Users\\\\me"\n',
        build_env_exports({"P": "C:\\Users\\me"}),
    )
    return unittest.end(env)

_env_exports_backslash_test = unittest.make(_env_exports_backslash_test_impl)

def _env_exports_combined_metachar_test_impl(ctx):
    """All metacharacters combined — validates escape ordering.

    Backslash must be escaped before dollar/backtick/quote; otherwise
    the backslashes inserted by earlier escapes get double-escaped.
    """
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        'export V="\\\\\\$\\`\\""\n',
        build_env_exports({"V": '\\$`"'}),
    )
    return unittest.end(env)

_env_exports_combined_metachar_test = unittest.make(_env_exports_combined_metachar_test_impl)

# --- Test suite ---

def common_test_suite(name):
    unittest.suite(
        name,
        _rlocation_workspace_file_test,
        _rlocation_external_repo_test,
        _pythonpath_basic_test,
        _pythonpath_empty_test,
        _pythonpath_single_entry_test,
        _env_exports_dollar_test,
        _env_exports_backtick_test,
        _env_exports_double_quote_test,
        _env_exports_backslash_test,
        _env_exports_combined_metachar_test,
    )
