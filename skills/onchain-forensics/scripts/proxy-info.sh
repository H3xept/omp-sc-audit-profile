#!/usr/bin/env bash
# proxy-info.sh <address> [--rpc-url URL] [--block N]
# Detects the proxy pattern behind <address>, prints implementation/admin/beacon
# slots, initializer state, and who controls the proxy (owner, ProxyAdmin owner,
# Safe owners/threshold/modules/guard, timelock delay).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$here/_common.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

TARGET="" RPC="" BLOCK=""
while (($#)); do
  case "$1" in
    -r|--rpc-url) RPC="${2:?}"; shift 2 ;;
    -B|--block) BLOCK="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    -*) die "unknown flag $1" ;;
    *) [[ -z "$TARGET" ]] || die "one address only"; TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || usage
need cast
require_rpc
[[ -n "$BLOCK" ]] && at_block "$BLOCK"

# Slot constants (keccak-derived; recomputable with `cast keccak` / `cast index-erc7201`).
S_IMPL=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc     # EIP-1967 implementation
S_ADMIN=0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103    # EIP-1967 admin
S_BEACON=0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50   # EIP-1967 beacon
S_ZOS_IMPL=0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3 # keccak("org.zeppelinos.proxy.implementation")
S_ZOS_ADMIN=0x10d6a54a4754c8869d6886b5f5d7fbfa5b4522237ea5c60d11bc4e7a1ff9390b # keccak("org.zeppelinos.proxy.admin")
S_1822=0xc5f16f0fcc639fa48a6947836d9850f504798523bf8c9a3a87d5876cf622bcf7     # keccak("PROXIABLE"), EIP-1822
S_INIT_V5=0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00  # ERC-7201 openzeppelin.storage.Initializable
S_SAFE_GUARD=0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8
S_SAFE_FALLBACK=0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5

code="$(code_of "$TARGET")"

echo "target:      $TARGET"
echo "chain-id:    $(cast chain-id --rpc-url "$RPC")"
echo "block:       ${BLOCK:-latest ($(cast block-number --rpc-url "$RPC"))}"
echo "code size:   $(( (${#code} - 2) / 2 )) bytes"
echo "codehash:    $(cast keccak "$code")"
if [[ "$code" == "0x" ]]; then
  echo "verdict:     no code at this address on this chain (EOA, not yet deployed, or wrong chain)"
  exit 1
fi

addr_of() { # addr_of <word> -> address or "" when zero/empty
  local w="$1"
  [[ -z "$w" || "$w" == "$ZERO_WORD" ]] && return 0
  word_addr "$w"
}

# describe_controller <address> <label> [depth]: classify an address that holds power,
# following owner() up to 3 hops.
describe_controller() {
  local who="$1" label="$2" depth="${3:-0}" c owners threshold delay modules
  [[ -z "$who" || "$who" == "$ZERO_ADDR" ]] && return 0
  c="$(code_of "$who")"
  if [[ "$c" == "0x" ]]; then
    echo "  $label $who: EOA (single key)"
    return 0
  fi
  if [[ "$c" == 0xef0100* ]]; then
    echo "  $label $who: EIP-7702 delegated EOA -> 0x${c:8:40} (key still controls it)"
    return 0
  fi
  owners="$(try_call "$who" 'getOwners()(address[])')"
  threshold="$(try_call "$who" 'getThreshold()(uint256)')"
  if [[ -n "$owners" && -n "$threshold" ]]; then
    modules="$(try_call "$who" 'getModulesPaginated(address,uint256)(address[],address)' 0x0000000000000000000000000000000000000001 50 | sed -n 1p)"
    echo "  $label $who: Safe threshold=$threshold owners=$owners"
    echo "    modules=${modules:-?} (each module executes without signatures)"
    local g f
    g="$(addr_of "$(slot "$who" "$S_SAFE_GUARD")")"
    f="$(addr_of "$(slot "$who" "$S_SAFE_FALLBACK")")"
    echo "    guard=${g:-none} fallbackHandler=${f:-none}"
    return 0
  fi
  delay="$(try_call "$who" 'getMinDelay()(uint256)')"
  if [[ -n "$delay" ]]; then
    echo "  $label $who: TimelockController minDelay=${delay}s (enumerate PROPOSER/EXECUTOR/CANCELLER with roles.sh)"
    return 0
  fi
  local o
  o="$(try_call "$who" 'owner()(address)')"
  echo "  $label $who: contract${o:+, owner()=$o}"
  if [[ -n "$o" && "$o" != "$who" && "$depth" -lt 3 ]]; then
    describe_controller "$o" "  $label.owner" $((depth + 1))
  fi
  return 0
}

# init_state <address> <label>: OZ Initializable state for v5 (ERC-7201) and the v4 slot-0 heuristic.
init_state() {
  local a="$1" label="$2" w v init flag w0
  w="$(slot "$a" "$S_INIT_V5")"
  if [[ -n "$w" && "$w" != "$ZERO_WORD" ]]; then
    v="${w:2}"
    flag=$(( 16#${v:46:2} ))
    if [[ "${v:48:16}" == ffffffffffffffff ]]; then
      echo "  $label: OZ v5 _initialized=type(uint64).max (initializers disabled) _initializing=$flag"
    else
      init=$(( 16#${v:48:16} ))
      echo "  $label: OZ v5 _initialized=$init _initializing=$flag"
    fi
  else
    w0="$(slot "$a" 0)"
    echo "  $label: ERC-7201 Initializable slot empty; slot0=${w0:-?} (OZ v4 layout only: low byte = _initialized, 0xff = disabled)"
  fi
}

impl="$(addr_of "$(slot "$TARGET" "$S_IMPL")")"
admin="$(addr_of "$(slot "$TARGET" "$S_ADMIN")")"
beacon="$(addr_of "$(slot "$TARGET" "$S_BEACON")")"
zimpl="$(addr_of "$(slot "$TARGET" "$S_ZOS_IMPL")")"
zadmin="$(addr_of "$(slot "$TARGET" "$S_ZOS_ADMIN")")"
p1822="$(addr_of "$(slot "$TARGET" "$S_1822")")"

kind="" logic="" upgrader="$admin"
if [[ "$code" == 0xef0100* && ${#code} -eq 48 ]]; then
  kind="EIP-7702 delegation designator (EOA delegating to code)"; logic="$(cast to-check-sum-address "0x${code:8:40}")"
elif [[ "$code" =~ ^0x363d3d373d3d3d363d73([0-9a-f]{40})5af43d82803e903d91602b57fd5bf3$ ]]; then
  kind="EIP-1167 minimal proxy (immutable, no upgrade path)"; logic="$(cast to-check-sum-address "0x${BASH_REMATCH[1]}")"
elif [[ -n "$beacon" ]]; then
  logic="$(try_call "$beacon" 'implementation()(address)')"
  kind="EIP-1967 beacon proxy (upgrade = beacon owner calls upgradeTo on the beacon)"
elif [[ -n "$impl" ]]; then
  logic="$impl"
  uuid="$(try_call "$impl" 'proxiableUUID()(bytes32)')"
  if [[ -n "$admin" ]]; then
    kind="EIP-1967 transparent proxy (admin slot set; upgrades via admin)"
  elif [[ "$uuid" == "$S_IMPL" ]]; then
    kind="EIP-1967 UUPS proxy (upgrade logic lives in the implementation)"
  else
    kind="EIP-1967 proxy, admin slot empty and implementation lacks proxiableUUID() (immutable admin or custom upgrade path — read the proxy source)"
  fi
elif [[ -n "$zimpl" ]]; then
  logic="$zimpl"; upgrader="$zadmin"
  kind="legacy zOS AdminUpgradeabilityProxy (transparent pattern, pre-EIP-1967 slots)"
elif [[ -n "$p1822" ]]; then
  logic="$p1822"; kind="EIP-1822 UUPS proxy (PROXIABLE slot)"
else
  safe_single="$(try_call "$TARGET" 'masterCopy()(address)')"
  facets="$(try_call "$TARGET" 'facetAddresses()(address[])')"
  if [[ -n "$safe_single" ]]; then
    kind="Safe proxy (singleton in slot 0)"; logic="$safe_single"
  elif [[ -n "$facets" ]]; then
    kind="EIP-2535 diamond (facets=$facets; enumerate selectors with facets())"
  else
    kind="no known proxy pattern detected (check \`cast disassemble\` for DELEGATECALL and custom slots)"
  fi
fi

echo "proxy type:  $kind"
echo "logic:       ${logic:-n/a}"
echo "slots:"
echo "  eip1967.implementation = ${impl:-0}"
echo "  eip1967.admin          = ${admin:-0}"
echo "  eip1967.beacon         = ${beacon:-0}"
[[ -n "$zimpl$zadmin" ]] && echo "  zos.implementation     = ${zimpl:-0}" && echo "  zos.admin              = ${zadmin:-0}"
[[ -n "$p1822" ]] && echo "  eip1822.PROXIABLE      = $p1822"

if [[ -n "$logic" && "$logic" != "$ZERO_ADDR" ]]; then
  lc="$(code_of "$logic")"
  echo "logic code:  $(( (${#lc} - 2) / 2 )) bytes, codehash $(cast keccak "$lc")"
fi

echo "initialization:"
init_state "$TARGET" "proxy storage"
[[ -n "$logic" && "$logic" != "$ZERO_ADDR" && "$kind" != EIP-7702* ]] && init_state "$logic" "implementation storage"

echo "control:"
owner="$(try_call "$TARGET" 'owner()(address)')"
echo "  owner() = ${owner:-n/a}"
pending="$(try_call "$TARGET" 'pendingOwner()(address)')"
[[ -n "$pending" && "$pending" != "$ZERO_ADDR" ]] && echo "  pendingOwner() = $pending"
describe_controller "$owner" "owner"
describe_controller "$upgrader" "proxy admin"
[[ -n "$beacon" ]] && describe_controller "$beacon" "beacon"
[[ "$kind" == Safe* ]] && describe_controller "$TARGET" "this Safe"
exit 0
