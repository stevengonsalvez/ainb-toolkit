#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
echo "[1/4] Ensuring 2048 game app binary..."
bash "${SCRIPT_DIR}/build_game.sh"

echo ""
echo "[2/4] Executing benchmark runner across arms..."
mkdir -p "${OUT_DIR}"
(
  cd "${SKILL_ROOT}"
  npx tsx scripts/runner.ts --arms "${ARMS}" --moves "${MOVES}" --out-dir "${OUT_DIR}"
)

echo ""
echo "[3/4] Post-processing frames, annotating, and stitching side-by-side video..."
python3 "${SCRIPT_DIR}/process_and_stitch.py" --results-dir "${OUT_DIR}" --arms "${ARMS}"

if [[ -n "$TRANSFER" ]]; then
  echo ""
  echo "[4/4] Transferring results to remote host: ${TRANSFER}"
  SSH_OPT=""
  if [[ -n "$SSH_KEY" ]]; then
    SSH_OPT="-i ${SSH_KEY}"
  fi
  REMOTE_HOST="${TRANSFER%%:*}"
  REMOTE_DIR="${TRANSFER#*:}"
  
  ssh ${SSH_OPT} -o StrictHostKeyChecking=no "${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR}'"
  scp ${SSH_OPT} "${OUT_DIR}"/*.mp4 "${OUT_DIR}"/BENCHMARK_REPORT.md "${TRANSFER}/"
  echo "[run] Transfer complete."
else
  echo ""
  echo "[4/4] Skipping remote transfer (no --transfer target specified)."
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
