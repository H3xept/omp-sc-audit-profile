#!/usr/bin/env bash
# bytecode-diff.sh <address> <artifact.json | ContractName> [--root DIR] [--block N] [--rpc-url URL]
# Compares deployed runtime code with a local Foundry build. Strips the trailing
# CBOR metadata from both sides, then reports every differing byte range and
# classifies it as an immutable slot, a library link, or UNEXPECTED.
# A contract name is resolved to <out>/**/<Name>.json under --root (default .)
# after `forge build`; build once with `forge build --ast` to name immutables.
# Exit 0 = only expected differences, 1 = unexpected ones.
# RPC is consumed by the helpers sourced from _common.sh.
# shellcheck disable=SC2034
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$here/_common.sh"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

TARGET="" ART="" ROOT=. BLOCK=""
while (($#)); do
  case "$1" in
    -r|--rpc-url) RPC="${2:?}"; shift 2 ;;
    --root) ROOT="${2:?}"; shift 2 ;;
    -B|--block) BLOCK="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    -*) die "unknown flag $1" ;;
    *) if [[ -z "$TARGET" ]]; then TARGET="$1"; elif [[ -z "$ART" ]]; then ART="$1"; else die "too many arguments"; fi; shift ;;
  esac
done
[[ -n "$TARGET" && -n "$ART" ]] || usage
need cast
need jq
require_rpc
[[ -n "$BLOCK" ]] && at_block "$BLOCK"

if [[ -f "$ART" ]]; then
  json="$ART"
else
  need forge
  (cd "$ROOT" && forge build >/dev/null) || die "forge build failed in $ROOT"
  out="$(cd "$ROOT" && forge config --json | jq -r .out)"
  matches=()
  while IFS= read -r f; do matches+=("$f"); done < <(find "$ROOT/$out" -type f \( -name "$ART.json" -o -name "$ART.*.json" \) | sort)
  ((${#matches[@]} > 0)) || die "no artifact named $ART under $ROOT/$out"
  ((${#matches[@]} == 1)) || die "ambiguous artifact; pass one path: ${matches[*]}"
  json="${matches[0]}"
fi

local_hex="$(lower "$(jq -r '.deployedBytecode.object // empty' "$json")")"
local_hex="${local_hex#0x}"
[[ -n "$local_hex" ]] || die "$json has no deployedBytecode.object (abstract contract or interface?)"
chain_hex="$(code_of "$TARGET")"
chain_hex="${chain_hex#0x}"
[[ -n "$chain_hex" ]] || die "no code at $TARGET"

# Expected-difference ranges, one per line: "<start> <length> <label>" in bytes.
# Immutables are named from the artifact AST when present, else by AST id.
ranges="$(jq -r '
  ([.ast // {} | .. | objects | select(.nodeType? == "VariableDeclaration") | {key: (.id | tostring), value: .name}]
    | from_entries) as $names
  | ((.deployedBytecode.immutableReferences // {}) | to_entries[] | .key as $id | .value[]
     | "\(.start) \(.length) immutable(\($names[$id] // "astId=\($id)"))"),
    ((.deployedBytecode.linkReferences // {}) | to_entries[] | .key as $f | .value | to_entries[]
     | .key as $lib | .value[] | "\(.start) \(.length) library(\($lib))")
' "$json")"
# A deployed library starts with PUSH20 <its own address> (call protection); solc emits zeros there.
if [[ "${local_hex:0:42}" == 730000000000000000000000000000000000000000 ]]; then
  ranges="$ranges"$'\n'"1 20 library-self-address"
fi

# meta_len <hex>: byte length of the trailing CBOR metadata incl. its 2-byte length, 0 if absent.
meta_len() {
  local h="$1" n m first
  n=$(( ${#h} / 2 ))
  ((n >= 2)) || { echo 0; return; }
  m=$(( 16#${h: -4} ))
  if (( m + 2 <= n )); then
    first=$(( 16#${h:$(( (n - 2 - m) * 2 )):2} ))
    if (( first >= 0xa0 && first <= 0xbf )); then echo $(( m + 2 )); return; fi
  fi
  echo 0
}
# solc_of <cbor hex>: compiler version from the "solc" key (64736f6c6343 + 3 bytes).
solc_of() {
  local v="${1#*64736f6c6343}"
  [[ "$v" != "$1" ]] || { echo "?"; return; }
  echo "$(( 16#${v:0:2} )).$(( 16#${v:2:2} )).$(( 16#${v:4:2} ))"
}

lm=$(meta_len "$local_hex")
cm=$(meta_len "$chain_hex")
local_meta="${local_hex:$(( ${#local_hex} - lm * 2 ))}"
chain_meta="${chain_hex:$(( ${#chain_hex} - cm * 2 ))}"
local_body="${local_hex:0:$(( ${#local_hex} - lm * 2 ))}"
chain_body="${chain_hex:0:$(( ${#chain_hex} - cm * 2 ))}"

echo "target:    $TARGET"
echo "artifact:  $json"
echo "deployed:  $(( ${#chain_hex} / 2 )) bytes (metadata $cm, solc $(solc_of "$chain_meta"))"
echo "local:     $(( ${#local_hex} / 2 )) bytes (metadata $lm, solc $(solc_of "$local_meta"))"
if [[ "$local_meta" == "$chain_meta" ]]; then
  echo "metadata:  identical (same sources and settings)"
else
  echo "metadata:  differs (sources, paths, comments, or settings changed; code may still match)"
fi

A="$chain_body" B="$local_body" RANGES="$ranges" awk '
  function covered(s, e,   i, ok) {   # 1 if every byte in [s,e] sits in one expected range
    for (i = s; i <= e; i++) { ok = 0
      for (k = 1; k <= nr; k++) if (i >= rs[k] && i < rs[k] + rl[k]) { ok = 1; break }
      if (!ok) return 0 }
    return 1 }
  function label(s,   k) { for (k = 1; k <= nr; k++) if (s >= rs[k] && s < rs[k] + rl[k]) return rn[k]; return "" }
  function flush() {
    if (start < 0) return
    kind = covered(start, stop) ? label(start) : "UNEXPECTED"
    if (kind == "UNEXPECTED") bad++; else ok++
    len = stop - start + 1
    if (ok + bad > 30) { hidden++; start = -1; return }
    printf "  0x%04x-0x%04x  %4d bytes  %-28s deployed=0x%s%s\n", start, stop, len, kind, substr(a, start * 2 + 1, (len > 32 ? 32 : len) * 2), (len > 32 ? "..." : "")
    start = -1 }
  BEGIN {
    a = ENVIRON["A"]; b = ENVIRON["B"]
    nr = split(ENVIRON["RANGES"], lines, "\n"); n = 0
    for (k = 1; k <= nr; k++) { if (lines[k] == "") continue; split(lines[k], f, " "); n++; rs[n] = f[1] + 0; rl[n] = f[2] + 0; rn[n] = f[3] }
    nr = n
    la = length(a) / 2; lb = length(b) / 2; max = la > lb ? la : lb
    start = -1; bad = 0; ok = 0
    print "diff ranges (offsets into runtime code, metadata excluded):"
    for (i = 0; i < max; i++) {
      differ = (i >= la || i >= lb) || substr(a, i * 2 + 1, 2) != substr(b, i * 2 + 1, 2)
      if (differ) { if (start < 0) start = i; stop = i }
      else flush()
    }
    flush()
    if (ok + bad == 0) print "  none"
    if (hidden) printf "  ... %d more ranges (an insertion shifts every later offset; the first UNEXPECTED range is where the code diverges)\n", hidden
    if (la != lb) { printf "length mismatch: deployed %d vs local %d bytes (different compiler settings or source)\n", la, lb; bad++ }
    printf "summary:   %d expected, %d unexpected\n", ok, bad
    shown = 0
    for (k = 1; k <= nr; k++) {
      if (rn[k] !~ /^immutable/ || seen[rn[k]]++) continue
      if (!shown++) print "immutable values (compare with audited constructor arguments):"
      printf "  %-28s 0x%s\n", rn[k], substr(a, rs[k] * 2 + 1, rl[k] * 2)
    }
    exit (bad > 0 ? 1 : 0)
  }'
