# shellcheck shell=bash
# Sourced by the onchain-forensics scripts. Not executable on its own.
# Portable to macOS /bin/bash 3.2: no ${x,,}, no associative arrays.
# Constants below are consumed by the scripts that source this file.
# shellcheck disable=SC2034

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH"; }

ZERO_WORD=0x0000000000000000000000000000000000000000000000000000000000000000
ZERO_ADDR=0x0000000000000000000000000000000000000000
RPC="${RPC:-}"
BLOCK_ARGS=()

lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

# require_rpc: fail unless RPC is set from --rpc-url or ETH_RPC_URL.
require_rpc() {
  RPC="${RPC:-${ETH_RPC_URL:-}}"
  [[ -n "$RPC" ]] || die "pass --rpc-url <url> or set ETH_RPC_URL"
}

# at_block <n>: pin every helper below to block <n>.
at_block() { BLOCK_ARGS=(--block "$1"); }

# code_of <address>: lowercase runtime code ("0x" when none).
code_of() { lower "$(cast code "$1" ${BLOCK_ARGS[@]+"${BLOCK_ARGS[@]}"} --rpc-url "$RPC")"; }

# slot <address> <slot>: raw 32-byte word ("" when the RPC call fails).
slot() { cast storage "$1" "$2" ${BLOCK_ARGS[@]+"${BLOCK_ARGS[@]}"} --rpc-url "$RPC" 2>/dev/null || true; }

# word_addr <word>: the low 20 bytes of a word as a checksummed address.
word_addr() { cast parse-bytes32-address "$1"; }

# try_call <address> <sig> [args...]: decoded return value, "" on revert/empty return.
try_call() {
  local to="$1" sig="$2"
  shift 2
  cast call "$to" "$sig" "$@" ${BLOCK_ARGS[@]+"${BLOCK_ARGS[@]}"} --rpc-url "$RPC" 2>/dev/null || true
}
