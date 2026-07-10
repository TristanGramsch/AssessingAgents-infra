#!/usr/bin/env bash
#
# run_engine.sh — Primitive engine runner for AssessingAgents.
#
# Validates the engine protocol, then runs each agent in dependency order
# using a coding harness (default: forge).  The harness gives each agent a
# working directory so it can read previous outputs and write its own files.
#
# API-key agnostic — reads LLM_PROVIDER, LLM_MODEL, INFRA_API_KEY from env.
#
# Usage:
#   INFRA_API_KEY="sk-..." ./run_engine.sh --run 1 --location Tralaland
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Parse arguments
# ---------------------------------------------------------------------------
RUN_ID=""
LOCATION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)      RUN_ID="$2"; shift 2 ;;
        --location) LOCATION="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument: $1"; exit 1 ;;
    esac
done

[[ -z "$RUN_ID"   ]] && echo "ERROR: --run is required"    && exit 1
[[ -z "$LOCATION" ]] && echo "ERROR: --location is required" && exit 1

# ---------------------------------------------------------------------------
# 2. Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="${SCRIPT_DIR}/engine"

PROFILES_DIR="${ENGINE_DIR}/organization/profiles"
INSTRUCTIONS_DIR="${ENGINE_DIR}/organization/instructions"
LOCATION_DIR="${ENGINE_DIR}/locations/${LOCATION}"
RUN_DIR="${ENGINE_DIR}/runs/${RUN_ID}"

# ---------------------------------------------------------------------------
# 3. Validate engine protocol
# ---------------------------------------------------------------------------
validate_engine() {
    local ok=true

    [[ -d "$PROFILES_DIR"    ]] || { echo "ERROR: missing $PROFILES_DIR";     ok=false; }
    [[ -d "$INSTRUCTIONS_DIR" ]] || { echo "ERROR: missing $INSTRUCTIONS_DIR"; ok=false; }
    [[ -d "$LOCATION_DIR"    ]] || { echo "ERROR: missing $LOCATION_DIR";     ok=false; }

    for agent in chief collector exemptor appraiser educator; do
        local f="${PROFILES_DIR}/${agent}.txt"
        [[ -f "$f" ]] || { echo "ERROR: missing profile: $f"; ok=false; }
    done

    for inst in 1_chief 2a_collector 2b_exemptor 3a_appraiser 4_educator 5_chief_review; do
        local f="${INSTRUCTIONS_DIR}/${inst}.txt"
        [[ -f "$f" ]] || { echo "ERROR: missing instruction: $f"; ok=false; }
    done

    $ok || exit 1
    echo "Engine protocol validated."
}

validate_engine

# ---------------------------------------------------------------------------
# 4. Set up run directory
# ---------------------------------------------------------------------------
DATA_DIR="${RUN_DIR}/data"
REPORTS_DIR="${RUN_DIR}/reports"

mkdir -p "$DATA_DIR" "$REPORTS_DIR"

# Copy location data files into data/ (read-only context for agents)
cp -r "${LOCATION_DIR}/"* "$DATA_DIR/" 2>/dev/null || true

CLIENT_INSTRUCTION_FILE="${RUN_DIR}/client_instruction.txt"
CLIENT_INSTRUCTION=""
if [[ -f "$CLIENT_INSTRUCTION_FILE" ]]; then
    CLIENT_INSTRUCTION=$(cat "$CLIENT_INSTRUCTION_FILE")
fi

LOG_FILE="${RUN_DIR}/api_log.txt"
:> "$LOG_FILE"

# ---------------------------------------------------------------------------
# 5. Coding harness selection (default: forge)
# ---------------------------------------------------------------------------
HARNESS="${CODING_HARNESS:-forge}"

if [[ "$HARNESS" != "forge" ]]; then
    echo "ERROR: unknown coding harness '${HARNESS}'. Supported: forge" >&2
    exit 1
fi

if ! command -v forge >/dev/null 2>&1; then
    echo "ERROR: 'forge' CLI not found on PATH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. LLM configuration (agnostic — all from env)
# ---------------------------------------------------------------------------
PROVIDER="${LLM_PROVIDER:-requesty}"
MODEL="${LLM_MODEL:-deepseek-v4-pro}"
API_KEY="${INFRA_API_KEY:-}"

[[ -z "$API_KEY" ]] && echo "ERROR: INFRA_API_KEY environment variable is not set" && exit 1

# Export provider-specific key (forge expects e.g. REQUESTY_API_KEY)
PROVIDER_KEY_VAR="$(echo "${PROVIDER}" | tr '[:lower:]' '[:upper:]')_API_KEY"
export "${PROVIDER_KEY_VAR}=${API_KEY}"

forge config set model "${PROVIDER}" "${MODEL}" 2>/dev/null || true

echo "Run ${RUN_ID} | ${PROVIDER} / ${MODEL} | harness: ${HARNESS}"

# ---------------------------------------------------------------------------
# 7. Agent definitions: (step_label, profile_file, instruction_file)
# ---------------------------------------------------------------------------
AGENTS=(
    "1_01_chief|chief.txt|1_chief.txt"
    "2_02_collector|collector.txt|2a_collector.txt"
    "3_03_exemptor|exemptor.txt|2b_exemptor.txt"
    "4_04_appraiser|appraiser.txt|3a_appraiser.txt"
    "5_05_educator|educator.txt|4_educator.txt"
    "6_06_chief_review|chief.txt|5_chief_review.txt"
)

TOTAL_STEPS="${#AGENTS[@]}"

# ---------------------------------------------------------------------------
# 8. Run each agent
# ---------------------------------------------------------------------------
step_num=0
for entry in "${AGENTS[@]}"; do
    step_num=$((step_num + 1))
    IFS='|' read -r step_label profile_file instruction_file <<< "$entry"

    echo "[${step_num}/${TOTAL_STEPS}] ${step_label}"

    PROFILE=$(cat "${PROFILES_DIR}/${profile_file}")
    INSTRUCTION=$(cat "${INSTRUCTIONS_DIR}/${instruction_file}")

    # Build prompt: profile + directory context + client instruction + agent instruction
    prompt="$(cat <<PROMPT
You are an agent of the AssessingAgents organization.

${PROFILE}

Your working directory is organized as follows:
- data/     : input files for this run (location data, client instruction). Read only.
- reports/  : outputs from all agents. Read peer reports here. Write your own report here.

CLIENT INSTRUCTION:
${CLIENT_INSTRUCTION}

===========================================================
${INSTRUCTION}
PROMPT
)"

    STEP_LOG="${RUN_DIR}/step_${step_label}_log.txt"

    # Run the agent via forge harness
    forge -C "${RUN_DIR}" -p "${prompt}" \
        > "$STEP_LOG" 2>&1 || {
        echo "ERROR: forge failed for ${step_label}" | tee -a "$LOG_FILE"
        echo "1" > "${RUN_DIR}/.exit_code"
        exit 1
    }

    # Strip ANSI escape sequences and Forge spinner lines from the log
    sed -i \
        -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
        -e '/· Ctrl+C to interrupt/d' \
        "$STEP_LOG"

    # Append to master log
    {
        echo "========================================"
        echo "STEP: ${step_label}"
        echo "========================================"
        cat "$STEP_LOG"
        echo ""
    } >> "$LOG_FILE"

    echo "  -> ${step_label} complete"
done

# ---------------------------------------------------------------------------
# 9. Success
# ---------------------------------------------------------------------------
echo "0" > "${RUN_DIR}/.exit_code"
echo "Run ${RUN_ID} completed successfully."