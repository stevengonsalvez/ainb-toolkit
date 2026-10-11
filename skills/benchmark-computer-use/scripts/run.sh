#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load the optional JEV key from Bitwarden when the caller has not supplied it.
if [[ -z "${TYPESAFE_API_KEY:-}" ]]; then
  SECRETS_DIR="${HOME}/.secrets"
  if [[ -f "${SECRETS_DIR}/bitwarden-credentials" && -f "${SECRETS_DIR}/bw-master" ]] && command -v bw >/dev/null 2>&1; then
    set +x
    set -a
    source "${SECRETS_DIR}/bitwarden-credentials"
    set +a
    export BW_CLIENTID="${BW_CLIENTID:-${BW_CLIENT_ID:-}}"
    export BW_CLIENTSECRET="${BW_CLIENTSECRET:-${BW_CLIENT_SECRET:-}}"
    export BW_SESSION="$(bw unlock --passwordfile "${SECRETS_DIR}/bw-master" --raw 2>/dev/null)"
    export TYPESAFE_API_KEY="$(bw get item TYPESAFE_API_KEY 2>/dev/null | jq -r '.fields[] | select(.name == "KEY") | .value')"
  fi
fi

ARMS="peekaboo,cuadriver,cua_jev"
MOVES=30
OUT_DIR="$(pwd)/benchmark-results"
SKIP_PREFLIGHT=false
TRANSFER=""
SSH_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arms)
      ARMS="$2"
      shift 2
      ;;
    --moves)
      MOVES="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$(cd "$2" 2>/dev/null && pwd || echo "$2")"
      shift 2
      ;;
    --transfer)
      TRANSFER="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="$2"
      shift 2
      ;;
    --skip-preflight)
      SKIP_PREFLIGHT=true
      shift
      ;;
    --help|-h)
      echo "Usage: ./run.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --arms <list>        Comma-separated arms: peekaboo,cuadriver,cua_jev,copilot (default: peekaboo,cuadriver,cua_jev)"
      echo "  --moves <N>          Number of moves per arm (default: 30)"
      echo "  --out-dir <path>     Directory for outputs (default: ./benchmark-results)"
      echo "  --transfer <target>  Optional SCP destination (e.g. user@host:~/Downloads/benchmark)"
      echo "  --ssh-key <path>     Optional SSH identity key for transfer"
      echo "  --skip-preflight     Skip environment preflight checks"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ ",${ARMS}," == *,cua_jev,* && -z "${TYPESAFE_API_KEY:-}" ]]; then
  echo "[run] TypeSafe key unavailable. Check Bitwarden item TYPESAFE_API_KEY and ~/.secrets setup." >&2
  exit 1
fi

echo "=========================================================="
echo " COMPUTER USE BENCHMARK RUNNER"
echo "=========================================================="
echo " Arms to test : ${ARMS}"
echo " Moves / arm  : ${MOVES}"
echo " Output dir   : ${OUT_DIR}"
echo "=========================================================="

if [[ "$SKIP_PREFLIGHT" != "true" ]]; then
  echo ""
  bash "${SCRIPT_DIR}/preflight.sh"
fi

echo ""
echo "[1/3] Executing benchmark runner against com.ainb.benchmark2048..."
mkdir -p "${OUT_DIR}"
(
  cd "${SKILL_ROOT}"
  npx tsx scripts/runner.ts --arms "${ARMS}" --moves "${MOVES}" --out-dir "${OUT_DIR}"
)

echo ""
echo "[2/3] Post-processing frames, annotating, and stitching side-by-side video..."
python3 "${SCRIPT_DIR}/process_and_stitch.py" --results-dir "${OUT_DIR}" --arms "${ARMS}"

if [[ -n "$TRANSFER" ]]; then
  echo ""
  echo "[3/3] Transferring results to remote host: ${TRANSFER}"
  SSH_OPT=""
  if [[ -n "$SSH_KEY" ]]; then
    SSH_OPT="-i ${SSH_KEY}"
  fi
  REMOTE_HOST="${TRANSFER%%:*}"
  REMOTE_DIR="${TRANSFER#*:}"
  
  ssh ${SSH_OPT} -o StrictHostKeyChecking=no "${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR}'"
  scp ${SSH_OPT} "${OUT_DIR}"/*.mp4 "${OUT_DIR}"/BENCHMARK_REPORT.md "${OUT_DIR}"/summary.json "${OUT_DIR}"/*_trace.jsonl "${TRANSFER}/" 2>/dev/null || scp ${SSH_OPT} "${OUT_DIR}"/*.mp4 "${OUT_DIR}"/BENCHMARK_REPORT.md "${TRANSFER}/"
  echo "[run] Transfer complete."
else
  echo ""
  echo "[3/3] Skipping remote transfer (no --transfer target specified)."
fi

echo ""
echo "=========================================================="
echo " BENCHMARK COMPLETED SUCCESSFULLY"
echo " Outputs available in: ${OUT_DIR}"
if [[ -f "${OUT_DIR}/benchmark_side_by_side.mp4" ]]; then
  echo " Side-by-side Video : ${OUT_DIR}/benchmark_side_by_side.mp4"
fi
if [[ -f "${OUT_DIR}/BENCHMARK_REPORT.md" ]]; then
  echo " Markdown Report    : ${OUT_DIR}/BENCHMARK_REPORT.md"
fi
echo "=========================================================="
