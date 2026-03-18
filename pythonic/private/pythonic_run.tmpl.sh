#!/usr/bin/env bash
# Launcher template for rules_pythonic test and binary targets.
# Variables in {{DOUBLE_BRACES}} are substituted at analysis time.

# --- Runfiles resolution (Bazel's bash runfiles library) ---
if [[ ! -d "${RUNFILES_DIR:-/dev/null}" && ! -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  if [[ -f "$0.runfiles_manifest" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
  elif [[ -f "$0.runfiles/MANIFEST" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles/MANIFEST"
  elif [[ -f "$0.runfiles/bazel_tools/tools/bash/runfiles/runfiles.bash" ]]; then
    export RUNFILES_DIR="$0.runfiles"
  fi
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

PYTHON="$(rlocation {{PYTHON_TOOLCHAIN}})"
PACKAGES_DIR="$(rlocation {{PACKAGES_DIR}})"

export PYTHONPATH="{{FIRST_PARTY_PYTHONPATH}}:${PACKAGES_DIR}"

{{PYTHON_ENV}}

# -B: skip .pyc (pointless in sandbox)  -s: ignore user site-packages (hermeticity)
exec "${PYTHON}" -B -s {{INTERPRETER_ARGS}} {{EXEC_CMD}} "$@"
