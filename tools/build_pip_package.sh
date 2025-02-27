#!/bin/bash
# Copyright 2021 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



# Create the TensorFlow Decision Forests pip package.
# This command uses the compiled artifacts generated by test_bazel.sh.
#
# Usage example:
#   # Generate the pip package with python3.8
#   ./tools/build_pip_package.sh python3.8
#
#   # Generate the pip package for all the versions of python using pyenv.
#   # Make sure the package are compatible with manylinux2010.
#   ./tools/build_pip_package.sh ALL_VERSIONS
#
# Requirements:
#
#   pyenv (if using ALL_VERSIONS_ALREADY_ASSEMBLED or ALL_VERSIONS)
#     See https://github.com/pyenv/pyenv-installer
#
#   Auditwheel
#     Note: "libtensorflow_framework.so.2" need to be added to the allowlisted
#     files (for example, in "policy.json" in "/home/${USER}/.local/lib/
#     python3.9/site-packages/auditwheel/policy/policy.json").
#     This change is done automatically (see "patch_auditwell" function). If
#     the automatic patch does not work, it has to be done manually by adding
#     "libtensorflow_framework.so.2" next to each "libresolv.so.2" entries
#     See https://github.com/tensorflow/tensorflow/issues/31807
#

set -xve

PLATFORM="$(uname -s | tr 'A-Z' 'a-z')"
function is_macos() {
  [[ "${PLATFORM}" == "darwin" ]]
}

# Make sure to use Gnu CP where needed.
if is_macos; then
  GCP="gcp"
else
  GCP="cp"
fi

# Temporary directory used to assemble the package.
SRCPK="$(pwd)/tmp_package"

function patch_auditwell() {
  PYTHON="$1"
  shift
  # Patch auditwheel for TensorFlow
  AUDITWHELL_DIR="$(${PYTHON} -m pip show auditwheel | grep "Location:")"
  AUDITWHELL_DIR="${AUDITWHELL_DIR:10}/auditwheel"
  echo "Auditwell location: ${AUDITWHELL_DIR}"
  POLICY_PATH="${AUDITWHELL_DIR}/policy/manylinux-policy.json"
  TF_DYNAMIC_FILENAME="libtensorflow_framework.so.2"
  if ! grep -q "${TF_DYNAMIC_FILENAME}" "${POLICY_PATH}"; then
    echo "Patching Auditwhell"
    cp "${POLICY_PATH}" "${POLICY_PATH}.orig"
    if is_macos; then
      sed -i '' "s/\"libresolv.so.2\"/\"libresolv.so.2\",\"${TF_DYNAMIC_FILENAME}\"/g" "${POLICY_PATH}"
    else
      sed -i "s/\"libresolv.so.2\"/\"libresolv.so.2\",\"${TF_DYNAMIC_FILENAME}\"/g" "${POLICY_PATH}"
    fi
  else
    echo "Auditwhell already patched"
  fi
}

# Pypi package version compatible with a given version of python.
# Example: Python3.8.2 => Package version: "38"
function python_to_package_version() {
  PYTHON="$1"
  shift
  ${PYTHON} -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")'
}

# Installs dependency requirement for build the Pip package.
function install_dependencies() {
  PYTHON="$1"
  shift
  ${PYTHON} -m ensurepip -U || true
  ${PYTHON} -m pip install pip -U
  ${PYTHON} -m pip install setuptools -U
  ${PYTHON} -m pip install build -U
  ${PYTHON} -m pip install virtualenv -U
  ${PYTHON} -m pip install auditwheel -U
}

function check_is_build() {
  # Check the correct location of the current directory.
  if [ ! -d "bazel-bin" ]; then
    echo "This script should be run from the root directory of TensorFlow Decision Forests (i.e. the directory containing the LICENSE file) of a compiled Bazel export (i.e. containing a bazel-bin directory)"
    exit 1
  fi
}

# Collects the library files into ${SRCPK}
function assemble_files() {
  check_is_build

  rm -fr ${SRCPK}
  mkdir -p ${SRCPK}
  cp -R tensorflow_decision_forests LICENSE configure/setup.py configure/MANIFEST.in README.md ${SRCPK}

  # TFDF's wrappers and .so.
  SRCBIN="bazel-bin/tensorflow_decision_forests"
  cp ${SRCBIN}/tensorflow/ops/inference/inference.so ${SRCPK}/tensorflow_decision_forests/tensorflow/ops/inference/
  cp ${SRCBIN}/tensorflow/ops/training/training.so ${SRCPK}/tensorflow_decision_forests/tensorflow/ops/training/

  # TODO(gbm): Include when Pip package support distributed training.
  # cp ${SRCBIN}/tensorflow/distribute/distribute.so ${SRCPK}/tensorflow_decision_forests/tensorflow/distribute/

  cp ${SRCBIN}/keras/wrappers.py ${SRCPK}/tensorflow_decision_forests/keras/

  # TFDF's proto wrappers.
  cp ${SRCBIN}/tensorflow/distribute/tf_distribution_pb2.py ${SRCPK}/tensorflow_decision_forests/tensorflow/distribute/

  # Distribution server binaries
  cp ${SRCBIN}/keras/grpc_worker_main ${SRCPK}/tensorflow_decision_forests/keras/

  # YDF's proto wrappers.
  YDFSRCBIN="bazel-bin/external/ydf/yggdrasil_decision_forests"
  mkdir -p ${SRCPK}/yggdrasil_decision_forests
  pushd ${YDFSRCBIN}
  find . -name \*.py -exec ${GCP} --parents -prv {} ${SRCPK}/yggdrasil_decision_forests \;
  popd

  # Add __init__.py to all exported Yggdrasil sub-directories.
  find ${SRCPK}/yggdrasil_decision_forests -type d -exec touch {}/__init__.py \;
}

# Build a pip package.
function build_package() {
  PYTHON="$1"
  shift

  pushd ${SRCPK}
  $PYTHON -m build
  popd

  cp -R ${SRCPK}/dist .
}

# Tests a pip package.
function test_package() {
  PYTHON="$1"
  shift
  PACKAGE="$1"
  shift

  PIP="${PYTHON} -m pip"

  if is_macos; then
    PACKAGEPATH="dist/tensorflow_decision_forests-*-cp${PACKAGE}-cp${PACKAGE}*-*.whl"
  else
    PACKAGEPATH="dist/tensorflow_decision_forests-*-cp${PACKAGE}-cp${PACKAGE}*-linux_x86_64.whl"
  fi
  ${PIP} install ${PACKAGEPATH}


  ${PIP} list
  ${PIP} show tensorflow_decision_forests -f

  # Run a small example
  ${PYTHON} examples/minimal.py
}

# Builds and tests a pip package in a given version of python
function e2e_native() {
  PYTHON="$1"
  shift
  PACKAGE=$(python_to_package_version ${PYTHON})

  install_dependencies ${PYTHON}
  patch_auditwell ${PYTHON}
  build_package ${PYTHON}
  test_package ${PYTHON} ${PACKAGE}

  # Fix package.
  if is_macos; then
    PACKAGEPATH="dist/tensorflow_decision_forests-*-cp${PACKAGE}-cp${PACKAGE}*-*.whl"
  else
    PACKAGEPATH="dist/tensorflow_decision_forests-*-cp${PACKAGE}-cp${PACKAGE}*-linux_x86_64.whl"
  fi
  auditwheel repair --plat manylinux2014_x86_64 -w dist ${PACKAGEPATH}
}

# Builds and tests a pip package in Pyenv.
function e2e_pyenv() {
  VERSION="$1"
  shift

  ENVNAME=env_${VERSION}
  pyenv install ${VERSION} -s

  # Enable pyenv
  set +e
  pyenv virtualenv ${VERSION} ${ENVNAME}
  set -e
  pyenv activate ${ENVNAME}

  e2e_native python3

  # Disable pyenv
  pyenv deactivate
}

ARG="$1"
shift | true

if [ -z "${ARG}" ]; then
  echo "The first argument should be one of:"
  echo "  ALL_VERSIONS: Build all pip packages using pyenv."
  echo "  ALL_VERSIONS_ALREADY_ASSEMBLED: Build all pip packages from already assembled files using pyenv."
  echo "  Python binary (e.g. python3.8): Build a pip package for a specific python version without pyenv."
  exit 1
elif [ ${ARG} == "ALL_VERSIONS" ]; then
  # Compile with all the version of python using pyenv.
  assemble_files
  eval "$(pyenv init -)"
  e2e_pyenv 3.9.2
  e2e_pyenv 3.8.7
  e2e_pyenv 3.7.7
  e2e_pyenv 3.10-dev
elif [ ${ARG} == "ALL_VERSIONS_ALREADY_ASSEMBLED" ]; then
  eval "$(pyenv init -)"
  e2e_pyenv 3.9.2
  e2e_pyenv 3.8.7
  e2e_pyenv 3.7.7
  e2e_pyenv 3.10-dev
else
  # Compile with a specific version of python provided in the call arguments.
  assemble_files
  PYTHON=${ARG}
  e2e_native ${PYTHON}
fi
