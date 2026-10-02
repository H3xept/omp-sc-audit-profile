#!/usr/bin/env bash
# roles.sh <address> [--from-block N] [--to-block N] [--query-size N] [--role NAME|bytes32] [--max-check N] [--rpc-url URL]
# Replays OpenZeppelin AccessControl RoleGranted/RoleRevoked/RoleAdminChanged logs
# into the current holder set per role, then cross-checks each holder with a live
# hasRole() call and, for AccessControlEnumerable, getRoleMemberCount().
# --from-block defaults to 0; set it to the deployment block (Etherscan
# get_contract_creation) on providers that reject wide ranges. --query-size is the
# per-request block chunk passed to `cast logs` (default 10000). Roles with more than
# --max-check holders (default 50; blocklists, allowlists) skip the live checks.
# Exit 1 = events and live state disagree for at least one holder.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$here/_common.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

TARGET="" FROM=0 TO=latest QSIZE=10000 ROLE="" MAXCHECK=50
while (($#)); do
  case "$1" in
    -r|--rpc-url) RPC="${2:?}"; shift 2 ;;
    --from-block) FROM="${2:?}"; shift 2 ;;
    --to-block) TO="${2:?}"; shift 2 ;;
    --query-size) QSIZE="${2:?}"; shift 2 ;;
    --role) ROLE="${2:?}"; shift 2 ;;
    --max-check) MAXCHECK="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    -*) die "unknown flag $1" ;;
    *) [[ -z "$TARGET" ]] || die "one address only"; TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || usage
need cast
need jq
require_rpc
[[ "$TO" == latest ]] && TO="$(cast block-number --rpc-url "$RPC")"
at_block "$TO"

GRANTED='RoleGranted(bytes32 indexed,address indexed,address indexed)'
REVOKED='RoleRevoked(bytes32 indexed,address indexed,address indexed)'
ADMIN_CHANGED='RoleAdminChanged(bytes32 indexed,bytes32 indexed,bytes32 indexed)'

fetch() { # fetch <event sig> -> JSON array of logs
  cast logs --address "$TARGET" "$1" --from-block "$FROM" --to-block "$TO" \
    --query-size "$QSIZE" --json --rpc-url "$RPC"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fetch "$GRANTED" >"$tmp/granted.json"
fetch "$REVOKED" >"$tmp/revoked.json"
fetch "$ADMIN_CHANGED" >"$tmp/admin.json"

# Well-known role names: keccak256("<NAME>") except DEFAULT_ADMIN_ROLE = 0x00.
names=(MINTER_ROLE BURNER_ROLE PAUSER_ROLE UNPAUSER_ROLE UPGRADER_ROLE ADMIN_ROLE OPERATOR_ROLE
  MANAGER_ROLE GUARDIAN_ROLE KEEPER_ROLE EXECUTOR_ROLE PROPOSER_ROLE CANCELLER_ROLE TIMELOCK_ADMIN_ROLE
  GOVERNOR_ROLE ORACLE_ROLE RELAYER_ROLE BRIDGE_ROLE TREASURY_ROLE STRATEGIST_ROLE HARVESTER_ROLE
  REWARDER_ROLE LIQUIDATOR_ROLE BLACKLIST_MANAGER_ROLE FREEZER_ROLE RESCUER_ROLE EMERGENCY_ROLE
  RISK_ADMIN_ROLE POOL_ADMIN_ROLE EMERGENCY_ADMIN_ROLE ASSET_LISTING_ADMIN_ROLE FLASH_BORROWER_ROLE
  GATEKEEPER_ROLE SOFT_RESTRICTED_STAKER_ROLE FULL_RESTRICTED_STAKER_ROLE)
{
  printf '%s\tDEFAULT_ADMIN_ROLE\n' "$ZERO_WORD"
  for n in "${names[@]}"; do printf '%s\t%s\n' "$(cast keccak "$n")" "$n"; done
} | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add' >"$tmp/names.json"

# Replay in (block, logIndex) order; output TSV: role, account, last block, granted-by.
jq -rs --slurpfile names "$tmp/names.json" '
  def num: if type == "number" then . else ltrimstr("0x") | ascii_downcase | explode
    | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end)) end;
  def addr: "0x" + .[26:];
  ([.[0][] | . + {kind: "grant"}] + [.[1][] | . + {kind: "revoke"}])
  | sort_by([(.blockNumber | num), (.logIndex | num)])
  | reduce .[] as $l ({}; ($l.topics[1]) as $r | ($l.topics[2] | addr) as $a
      | if $l.kind == "grant"
        then .[$r][$a] = {block: ($l.blockNumber | num), by: ($l.topics[3] | addr)}
        else del(.[$r][$a]) end)
  | to_entries[] | .key as $r | (.value | to_entries[]) |
    [$r, ($names[0][$r] // "?"), .key, (.value.block | tostring), .value.by] | @tsv
' "$tmp/granted.json" "$tmp/revoked.json" >"$tmp/holders.tsv"

ngrant=$(jq length "$tmp/granted.json")
nrevoke=$(jq length "$tmp/revoked.json")
echo "target:  $TARGET"
echo "range:   blocks $FROM..$TO (RoleGranted=$ngrant RoleRevoked=$nrevoke)"
if [[ "$FROM" != 0 ]]; then
  # No code one block before FROM means the replay starts at or before deployment.
  before="$(cast code "$TARGET" --block $((FROM - 1)) --rpc-url "$RPC" 2>/dev/null || echo unknown)"
  if [[ "$before" == 0x ]]; then
    echo "coverage: complete (no code at block $((FROM - 1)))"
  else
    echo "coverage: PARTIAL — code existed before block $FROM (or the RPC lacks archive state); grants earlier than that are invisible"
  fi
fi

roles=$(cut -f1 "$tmp/holders.tsv" | sort -u)
if [[ -n "$ROLE" ]]; then
  case "$ROLE" in
    0x*) ROLE="$(lower "$ROLE")" ;;
    DEFAULT_ADMIN_ROLE) ROLE="$ZERO_WORD" ;;
    *) ROLE="$(cast keccak "$ROLE")" ;;
  esac
  roles=$(printf '%s\n' "$roles" | awk -v r="$ROLE" '$0 == r')
fi
admin_changes=$(jq -r '.[] | [.topics[1], .topics[3]] | @tsv' "$tmp/admin.json")
mismatch=0
for r in $roles; do
  name=$(jq -r --arg r "$r" '.[$r] // "?"' "$tmp/names.json")
  roleadmin=$(try_call "$TARGET" 'getRoleAdmin(bytes32)(bytes32)' "$r")
  count=$(try_call "$TARGET" 'getRoleMemberCount(bytes32)(uint256)' "$r")
  replayed=$(awk -F'\t' -v r="$r" '$1 == r' "$tmp/holders.tsv" | wc -l | tr -d ' ')
  echo
  echo "role $r ($name)"
  echo "  admin role: ${roleadmin:-?} ($(jq -r --arg r "${roleadmin:-x}" '.[$r] // "?"' "$tmp/names.json"))"
  if [[ -n "$count" ]]; then
    flag=""
    [[ "${count%% *}" != "$replayed" ]] && flag="  <-- MISMATCH: replay missed holders (widen --from-block)" && mismatch=1
    echo "  getRoleMemberCount=${count%% *} replayed=$replayed$flag"
  fi
  check=1
  if ((replayed > MAXCHECK)); then
    check=0
    echo "  $replayed holders > --max-check $MAXCHECK: live hasRole/code checks skipped (rerun with --role $r --max-check $replayed)"
  fi
  while IFS=$'\t' read -r _ _ acct blk by; do
    line="  $(cast to-check-sum-address "$acct")"
    if ((check)); then
      live=$(try_call "$TARGET" 'hasRole(bytes32,address)(bool)' "$r" "$acct")
      code=$(code_of "$acct" 2>/dev/null || echo "?")
      case "$code" in
        0x) kind=EOA ;;
        0xef0100*) kind="EOA(7702->0x${code:8:40})" ;;
        "?") kind="?" ;;
        *) kind=contract ;;
      esac
      line="$line  $kind"
      if [[ "$live" == false ]]; then
        line="$line  <-- hasRole=false (state diverged from events)"; mismatch=1
      elif [[ "$live" != true ]]; then
        line="$line  <-- hasRole call failed (RPC error or no hasRole)"; mismatch=1
      fi
    fi
    echo "$line  granted@$blk by $(cast to-check-sum-address "$by")"
  done < <(awk -F'\t' -v r="$r" '$1 == r' "$tmp/holders.tsv")
done
if [[ -n "$admin_changes" ]]; then
  echo
  echo "RoleAdminChanged (role -> new admin role):"
  printf '%s\n' "$admin_changes" | sed 's/^/  /'
fi
[[ -n "$roles" ]] || echo "no RoleGranted logs in range (not AccessControl, custom events, or range too narrow)"
exit "$mismatch"
