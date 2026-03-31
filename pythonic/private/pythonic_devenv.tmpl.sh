#!/usr/bin/env bash
# Launcher template for pythonic_devenv.
# Variables in {{DOUBLE_BRACES}} are substituted at analysis time.
#
# Unlike the test/binary launcher, this runs via `bazel run` and writes to the
# real filesystem. It creates a Python venv at $BUILD_WORKSPACE_DIRECTORY/<path>
# and populates it with third-party wheels and editable first-party packages.
# The setup script needs two root paths:
#   - $BUILD_WORKSPACE_DIRECTORY: the real workspace, for editable source paths
#   - $RUNFILES_DIR: where Bazel stages wheels, pyproject.toml files, and the
#     uv binary — these are rlocation keys in the JSON manifest

# Runfiles are the files Bazel makes available at runtime (wheels, pyproject.toml
# files, the Python interpreter, uv). They live in a directory tree next to the
# executable, but its location varies by platform and execution strategy.
# This boilerplate finds the runfiles directory and loads Bazel's rlocation()
# helper, which translates workspace-relative paths to absolute paths at runtime.
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
#   UV="$(rlocation rules_multitool++multitool+multitool/tools/uv/uv)"
#   exec "${PYTHON}" -B -s "$(rlocation rules_pythonic+/.../setup_devenv.py)" \
#       --manifest "$(rlocation _main/devenv_manifest.json)" \
#       --uv-bin "$UV" --python-bin "${PYTHON}" \
#       --workspace-dir "${BUILD_WORKSPACE_DIRECTORY}" \
#       --runfiles-dir "${RUNFILES_DIR}"
PYTHON="$(rlocation {{PYTHON_TOOLCHAIN}})"
UV="$(rlocation {{UV_TOOLCHAIN}})"

# -B: skip .pyc  -s: ignore user site-packages
exec "${PYTHON}" -B -s "$(rlocation {{SETUP_SCRIPT}})" \
    --manifest "$(rlocation {{MANIFEST}})" \
    --uv-bin "$UV" \
    --python-bin "${PYTHON}" \
    --workspace-dir "${BUILD_WORKSPACE_DIRECTORY}" \
    --runfiles-dir "${RUNFILES_DIR}"
