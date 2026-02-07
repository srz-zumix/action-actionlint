#!/bin/bash
set -eu

if [ "${RUNNER_DEBUG:-}" = "1" ] ; then
  set -x
fi

mkdir -p "${INPUT_OUTPUT_DIR}"
OUTPUT_FILE_NAME="reviewdog-${INPUT_TOOL_NAME}"
if [[ "${INPUT_REPORTER}" == "sarif" ]]; then
  OUTPUT_FILE_NAME="${OUTPUT_FILE_NAME}.sarif"
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

cd "${RUNNER_TEMP}" || exit 1

if [ -z "${RUNNER_TOOL_CACHE:-}" ]; then
  RUNNER_TOOL_CACHE="$(mktemp -d)"
fi

echo '::group:: Installing shellcheck ... https://github.com/koalaman/shellcheck'
SHELLCHECK_PATH="${RUNNER_TOOL_CACHE}/shellcheck/${SHELLCHECK_VERSION}"
mkdir -p "${SHELLCHECK_PATH}/bin"

install_shellcheck() {
  local WINDOWS_TARGET=zip
  
  # Get system architecture
  local ARCH=$(uname -m)
  if [[ "${ARCH}" == "arm64" || "${ARCH}" == "aarch64" ]]; then
    CPU_ARCH="aarch64"
  else
    CPU_ARCH="x86_64"
  fi
  
  # Set targets based on OS and architecture
  if [[ $(uname -s) == "Linux" ]]; then
    local LINUX_TARGET="linux.${CPU_ARCH}.tar.xz"
    curl -sL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.${LINUX_TARGET}" | tar -xJf -
    cp "shellcheck-v$SHELLCHECK_VERSION/shellcheck" "${SHELLCHECK_PATH}/bin"
  elif [[ $(uname -s) == "Darwin" ]]; then
    local MACOS_TARGET="darwin.${CPU_ARCH}.tar.xz"
    curl -sL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.${MACOS_TARGET}" | tar -xJf -
    cp "shellcheck-v$SHELLCHECK_VERSION/shellcheck" "${SHELLCHECK_PATH}/bin"
  else
    curl -sL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.${WINDOWS_TARGET}" -o "shellcheck-v${SHELLCHECK_VERSION}.${WINDOWS_TARGET}" && unzip "shellcheck-v${SHELLCHECK_VERSION}.${WINDOWS_TARGET}" && rm "shellcheck-v${SHELLCHECK_VERSION}.${WINDOWS_TARGET}"
    cp "shellcheck.exe" "${SHELLCHECK_PATH}/bin"
  fi
}

if [ ! -f "${SHELLCHECK_PATH}/bin/shellcheck" ] && [ ! -f "${SHELLCHECK_PATH}/bin/shellcheck.exe" ]; then
    install_shellcheck
else
    echo "shellcheck v${SHELLCHECK_VERSION} is already installed."
fi

PATH="${SHELLCHECK_PATH}/bin:$PATH"
shellcheck --version
echo '::endgroup::'

# path to pyflakes
PATH="${GITHUB_ACTION_PATH}/bin:$PATH"
pyflakes --version
  
echo '::group::🐶 Installing actionlint ... https://github.com/rhysd/actionlint'

install_actionlint() {
  ACTIONLINT_PATH="${RUNNER_TOOL_CACHE}/actionlint/${ACTIONLINT_VERSION}"
  mkdir -p "${ACTIONLINT_PATH}/bin"
  cd "${ACTIONLINT_PATH}/bin" || exit 1
  bash <(curl https://raw.githubusercontent.com/rhysd/actionlint/f8a7ad2624edffd2d432f5b4f40d79b92e48df6a/scripts/download-actionlint.bash) "${ACTIONLINT_VERSION}"
}

if [ ! -f "${RUNNER_TOOL_CACHE}/actionlint/${ACTIONLINT_VERSION}/bin/actionlint" ]; then
    install_actionlint
else
    echo "actionlint v${ACTIONLINT_VERSION} is already installed."
fi

PATH="${ACTIONLINT_PATH}/bin:$PATH"
actionlint --version
echo '::endgroup::'

if [ -n "${GITHUB_WORKSPACE}" ]; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit
  git config --global --add safe.directory "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit 1
fi

echo '::group:: Running actionlint with reviewdog 🐶 ...'
# shellcheck disable=SC2086
actionlint -oneline ${INPUT_ACTIONLINT_FLAGS} | while read -r r; do
  shellcheck_output=" shellcheck reported issue in this script: "
  severity=e

  # Parse the severity if the output is from shellcheck
  if echo "${r}" | grep "${shellcheck_output}"; then
    s="$(echo "${r}" | sed -e "s/^.*${shellcheck_output}[^:]*:\([^:]\).*$/\1/g")"
    if [ "${s}" = 'e' ] || [ "${s}" = 'w' ] || [ "${s}" = 'i' ] || [ "${s}" = 'n' ]; then
      severity="${s}"
    fi
  fi

  echo "${severity}:${r}"
done \
    | reviewdog \
        -efm="%t:%f:%l:%c: %m" \
        -name="${INPUT_TOOL_NAME}" \
        -reporter="${INPUT_REPORTER}" \
        -filter-mode="${INPUT_FILTER_MODE}" \
        -fail-level="${INPUT_FAIL_LEVEL}" \
        -level="${INPUT_LEVEL}" \
        ${INPUT_REVIEWDOG_FLAGS}

exit_code=$?
echo '::endgroup::'
exit "$exit_code"
