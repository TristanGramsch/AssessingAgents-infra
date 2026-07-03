#!/usr/bin/env bash
#
# clone_engine.sh
#
# Makes sure a working copy of the AssessingAgents engine repo exists at
# ENGINE_DIR. The engine is treated as an external dependency: this
# script's only job is clone-if-missing / pull-if-present.
#
# Usage:
#   ./clone_engine.sh [repo-url] [engine-dir]
#
# Defaults:
#   repo-url   = https://github.com/TristanGramsch/AssessingAgents.git
#   engine-dir = ./engine
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_URL="${1:-https://github.com/TristanGramsch/AssessingAgents.git}"
ENGINE_DIR="${2:-${SCRIPT_DIR}/engine}"

if [[ -d "${ENGINE_DIR}/.git" ]]; then
  echo "Engine already present at ${ENGINE_DIR}, pulling latest..."
  git -C "${ENGINE_DIR}" pull
else
  echo "Cloning ${REPO_URL} into ${ENGINE_DIR}..."
  git clone "${REPO_URL}" "${ENGINE_DIR}"
fi

chmod +x "${ENGINE_DIR}/run_assessment.sh"
echo "Engine ready at ${ENGINE_DIR}"
