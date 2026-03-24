#!/usr/bin/env bash
# Launcher template for rules_pythonic test and binary targets.
# Variables in {{DOUBLE_BRACES}} are substituted at analysis time.

# Runfiles are the files Bazel makes available at runtime (test sources, packages,
# the Python interpreter). They live in a directory tree next to the executable,
# but its location varies by platform and execution strategy (sandbox, remote, local).
# This boilerplate finds the runfiles directory and loads Bazel's rlocation() helper,
# which translates workspace-relative paths to absolute paths at runtime.
# See: https://bazel.build/extending/rules#runfiles
if [[ ! -d "${RUNFILES_DIR:-/dev/null}" && ! -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  if [[ -f "$0.runfiles_manifest" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
  elif [[ -f "$0.runfiles/MANIFEST" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles/MANIFEST"
  elif [[ -f "$0.runfiles/bazel_tools/tools/bash/runfiles/runfiles.bash" ]]; then
    export RUNFILES_DIR="$0.runfiles"
  fi
fi
# Ensure RUNFILES_DIR is set even in manifest mode. rlocation falls back to
# filesystem for directory paths (not present in the manifest).
if [[ -z "${RUNFILES_DIR:-}" && -d "$0.runfiles" ]]; then
  export RUNFILES_DIR="$0.runfiles"
fi
if [[ -f "${RUNFILES_DIR:-/dev/null}/bazel_tools/tools/bash/runfiles/runfiles.bash" ]]; then
  source "${RUNFILES_DIR}/bazel_tools/tools/bash/runfiles/runfiles.bash"
elif [[ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  source "$(grep -m1 "^bazel_tools/tools/bash/runfiles/runfiles.bash " \
    "$RUNFILES_MANIFEST_FILE" | cut -d ' ' -f 2-)"
else
  echo >&2 "ERROR: cannot find @bazel_tools//tools/bash/runfiles:runfiles.bash"
  exit 1
fi

set -o errexit -o nounset -o pipefail

# After substitution, a concrete launcher looks like:
#   PYTHON="$(rlocation rules_python++python+python_3_11/bin/python3)"
#   PACKAGES_DIR="$(rlocation _main/mypackage/test_greeting_packages)"
#   export PYTHONPATH="$(rlocation _main/mypackage/src)":${PACKAGES_DIR}
#   exec "${PYTHON}" -B -s "$(rlocation rules_pythonic+/.../pythonic_pytest_runner.py)" "$(rlocation _main/.../test_foo.py)" "$@"
PYTHON="$(rlocation {{PYTHON_TOOLCHAIN}})"
PACKAGES_DIR="$(rlocation {{PACKAGES_DIR}})"

export PYTHONPATH="{{FIRST_PARTY_PYTHONPATH}}${PACKAGES_DIR}"

{{PYTHON_ENV}}

# -B: skip .pyc (pointless in sandbox)  -s: ignore user site-packages (hermeticity)
exec "${PYTHON}" -B -s {{INTERPRETER_ARGS}} {{EXEC_CMD}} "$@"
