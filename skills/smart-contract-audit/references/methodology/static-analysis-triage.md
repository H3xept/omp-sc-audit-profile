# Static analysis triage

How to turn Slither and Aderyn output into review anchors fast. A detector hit marks a line worth reading; the finding is the mechanism you then prove. Every hit leaves triage in exactly one state: **anchor** (a hypothesis to hunt, tied to an invariant), **dismissed** (with the evidence that clears it), or **duplicate** (of an anchor with the same root cause).

Names, flags, and outputs below were checked against slither 0.11.5 (`--help`, `--list-detectors`, `--list-printers`, and the wiki pages [Detector Documentation](https://github.com/crytic/slither/wiki/Detector-Documentation), [Printer documentation](https://github.com/crytic/slither/wiki/Printer-documentation), [Upgradeability Checks](https://github.com/crytic/slither/wiki/Upgradeability-Checks), [Usage](https://github.com/crytic/slither/wiki/Usage)), and against aderyn 0.6.8 ([detector source](https://github.com/Cyfrin/aderyn/tree/aderyn-v0.6.8/aderyn_core/src/detect)) plus a local aderyn 0.1.9 binary. Detector sets change between releases; `slither --list-detectors` and `aderyn registry` print the names your installed versions accept.

## Procedure

### Step 1 — Run on scope only

The pipeline's SETUP phase already writes `.sc-audit/raw/slither-findings.json` and `.sc-audit/raw/aderyn-findings.json`; reuse them when present. Otherwise:

```bash
slither . --exclude-dependencies --filter-paths "(lib/|test/|script/|mocks/)" --json .sc-audit/raw/slither-findings.json
aderyn . -o .sc-audit/raw/aderyn-findings.json          # -x <paths> excludes, -i <paths> includes
```

Slither exits non-zero when it finds anything; success is "the JSON exists and parses". Slither JSON: `results.detectors[]` with `check`, `impact`, `confidence`, `description`, `first_markdown_element`. Aderyn JSON: `high_issues.issues[]` and `low_issues.issues[]`, each with `detector_name` and `instances[]` of `contract_path` and `line_no`.

**Done when** both JSON files parse and every remaining hit is in an in-scope file.

### Step 2 — Bucket by signal, not by tool severity

Group hits by detector. Order the groups by the tables below — high-signal first — rather than by the tool's impact label: Slither rates `reentrancy-benign` Low and `divide-before-multiply` Medium, but a single `arbitrary-send-erc20` hit outranks fifty of either.

**Done when** every detector group sits in one bucket: high-signal, context-dependent, or typically noisy.

### Step 3 — Confirm or dismiss each hit

Open the flagged line and run the detector's check from the tables. A confirmed hit becomes a hypothesis in the form the threat model uses — "`<function>` can break `INV-xxx` when `<condition>`" (`skill://smart-contract-audit/references/methodology/threat-model.md`, Step 6) — and goes into the hunt. A dismissed hit gets its reason and the file:line of the code that clears it. Hits sharing one root cause collapse into one anchor.

**Done when** every hit in the high-signal and context-dependent buckets is anchor, dismissed, or duplicate; and every noisy-bucket group is either dismissed as a group with one sampled line checked, or promoted hit by hit.

### Step 4 — Record

Write `.sc-audit/triage.md`:

| Tool | Detector | Location | Verdict | Evidence |
|---|---|---|---|---|
| slither | `reentrancy-eth` | `EtherVault.sol:11-17` | anchor → H-03 | `msg.sender.call` at :14 before `balanceOf[msg.sender] = 0` at :16; no `nonReentrant` on `withdraw` or `deposit` |
| slither | `arbitrary-send-eth` | `Router.sol:88` | dismissed: caller-bound | recipient is `msg.sender`, amount is `credit[msg.sender]` zeroed at :86 |
| aderyn | `centralization-risk` | `ToyVault.sol:50,54` | dismissed: trusted role | `onlyOwner` setters; trust assumption recorded in `SYSTEM.md` |

Dismissal reasons come from a closed set so a reader can audit them: **guarded** (guard at file:line blocks every path), **caller-bound** (the value or target is the caller's own), **trusted callee** (fixed address, no callback into untrusted code), **unreachable** (no entry point reaches the line with attacker-influenced data — cite `slither-find-paths`), **out of model** (token or actor excluded by scope — cite the scope line), **non-value** (no state or value depends on it), **by design** (documented behavior with no security impact — cite the doc).

The target repository stays read-only (`AGENTS.md`), so dismissals live in `triage.md`, never as `// slither-disable-next-line` comments in the target. Slither's interactive `--triage-mode` writes `slither.db.json` to the working directory by default; point it at the work directory with `--triage-database .sc-audit/slither.db.json` when you use it.

This record feeds MAP's `static_summary.likely_real` and REPORT's Static Analysis Summary ("confirmed versus false positive").

**Done when** `triage.md` has one row per hit or per dismissed noisy group, and every dismissal carries a reason from the set plus a file:line.

## Slither — high-signal detectors

Rare on correct code; each hit gets a full read.

| Detector | What it flags | Confirm when | Dismiss when |
|---|---|---|---|
| `arbitrary-send-erc20` | `transferFrom` whose `from` is not `msg.sender` | a caller can name a `from` that has approved this contract (routers, zappers, vaults with standing approvals) and the tokens go somewhere the caller chooses | `from` is `address(this)`, a fixed trusted address, or bound to `msg.sender` through a verified signature |
| `arbitrary-send-erc20-permit` | same, after a `permit` call | the permit signature is not checked to belong to `from`, or a failing permit is swallowed (`try/catch`) and a standing approval is spent — see catalog A6 in `skill://smart-contract-audit/references/weird-erc20.md` | `from` is the permit signer and the permit result gates the transfer |
| `arbitrary-send-eth` | ETH sent to an address the caller influences | the recipient or amount comes from calldata or from storage a non-admin can write, and the amount is not the caller's own credited balance | the recipient is `msg.sender` and the amount is their own balance zeroed before the send |
| `controlled-delegatecall` | `delegatecall`/`callcode` to a caller-influenced target | any non-admin path sets the target or calldata; or a router/multicall delegates into a user-chosen module | target is a proxy implementation slot written only by the upgrade path, or an immutable allowlist |
| `reentrancy-eth` | state written after an external call that sends ETH | the callee can be attacker code (`msg.sender`, user-supplied recipient or token, ERC-721/1155 receiver hook, ERC-777 hook) and some entry point reads the late-written state to pay out | `nonReentrant` covers every function that reads or writes that state, or the callee is a trusted contract with no callback path |
| `reentrancy-no-eth` | same, no ETH involved | same as above; check token hooks (catalog E1, E3) and cross-function paths | same as above |
| `reentrancy-balance` | a `balanceOf` read before an external call, reused after it | the call can reenter or transfer so the stale balance misprices shares or a payout | the call target is a fixed token with no hooks and no attacker-controlled transfer can happen in between |
| `uninitialized-state` | a state variable read but never written | a guard or a payout reads it (an `owner` left zero, a fee recipient left zero, a mapping never populated) | it is written through assembly, an inherited initializer, or a `delegatecall`-ed module Slither did not trace — show the write |
| `unprotected-upgrade` | a logic contract with an unguarded `initialize` and a path to `selfdestruct` or `delegatecall` | the implementation constructor does not call `_disableInitializers()` (or equivalent) and the initialized role can reach the destructive path; on chains without EIP-6780, `selfdestruct` on the implementation bricks every proxy | initializers are disabled in the implementation constructor. Since EIP-6780 (Cancun), `selfdestruct` outside the creating transaction no longer deletes code — check the target chain's EVM before rating |
| `msg-value-loop` | `msg.value` read inside a loop | the loop credits `msg.value` per iteration, or a `multicall` delegates into payable functions so one payment is counted many times | the loop only compares `msg.value` against a total computed outside it |
| `encode-packed-collision` | `abi.encodePacked` of two or more dynamic types fed to a hash | the hash keys an authorization, signature, or uniqueness check and an attacker can shift bytes between adjacent arguments | the hash is informational only, or arguments are fixed-length |
| `weak-prng` | modulo on `block.timestamp`, `blockhash`, or similar | the result picks a winner, a rarity, or an amount — an attacker contract computes the same value in the same transaction and reverts when it loses | the value does not decide value |
| `incorrect-exp` | `^` (xor) where `**` was meant | evaluate the expression at the values used; xor almost never equals the intended power | the author meant xor — show the bitwise intent |
| `incorrect-shift` | shift operands reversed in assembly (`shl(value, bits)` instead of `shl(bits, value)`) | evaluate the shift at the values used | operands are in the intended order |
| `suicidal` | `selfdestruct` callable without access control | anyone can reach it: before EIP-6780 (or on chains without it) the code is deleted; after it, outside the creating transaction, the code stays and the whole ETH balance goes to the `selfdestruct` beneficiary — rate on what that does to the system | the call is guarded or unreachable |
| `uninitialized-storage` | a storage pointer declared without assignment, aliasing slot 0 | a write through the pointer overwrites a critical variable on a reachable path | the pointer is assigned before every use |
| `storage-array`, `abiencoderv2-array` | solc 0.4.7–0.5.9 bugs with signed storage arrays and ABI encoder v2 arrays | the build uses an affected compiler and the pattern is on a reachable path | the compiler is outside 0.4.7–0.5.9 |

## Slither — context-dependent detectors

Real often enough to read every hit; usually the question is "does value depend on it".

| Detector | Confirm when | Dismiss when |
|---|---|---|
| `incorrect-equality` | the compared value can be moved by someone else — a contract balance moved by direct transfer or forced ETH, a total moved by a donation — and the equality gates progress (a state machine stuck forever, a sale that never closes) | the comparison is on a value only the caller controls, or a zero-check on an early-return path |
| `divide-before-multiply` | compute the truncation at realistic magnitudes and decimals; confirmed when the lost amount crosses the material threshold in `skill://smart-contract-audit/references/methodology/severity.md`, or rounds in the attacker's favour each call. A fuzz differential against the reordered expression proves it | the truncation is bounded by one unit of the smallest denomination per call and cannot be looped for profit — record as dust |
| `unchecked-transfer` | an in-scope token returns `false` instead of reverting (catalog A3, A4) and the code credits the user anyway | every in-scope token reverts on failure, or the call uses `SafeERC20` — record which tokens the scope allows |
| `unused-return` | the ignored value is a real outcome: amounts out from a swap, `latestRoundData` fields the code needs for staleness, the `bool` from `approve`, the shares minted by an external vault | the return value is informational and the call reverts on failure |
| `unchecked-lowlevel`, `unchecked-send` | the call's failure leaves value credited or a state transition done | failure is impossible or irrelevant to accounting |
| `tx-origin` | `tx.origin` authorizes an action, so a contract the victim calls can act as the victim | `tx.origin` is used only to block contracts or for logging |
| `locked-ether` | a payable path can receive ETH that no function can release | the payable function is required by an interface and rejects nonzero value, or ETH is meant to stay |
| `calls-loop` | one failing or gas-heavy callee (a blocklisted recipient, catalog D4; a reverting receiver) blocks payouts to everyone else | callees are trusted or failures are caught per iteration |
| `return-bomb` | the caller must not revert (a relayer, liquidation, cross-chain executor, or keeper) and the callee is untrusted | the callee is trusted, or the caller copies bounded returndata |
| `missing-zero-check` | a zero address makes funds unrecoverable and the setter is one-shot (constructor, immutable) or callable by a non-admin | an admin setter that can be called again — out of model under the privilege rule |
| `pyth-unchecked-confidence`, `pyth-unchecked-publishtime`, `chronicle-unchecked-price`, `chainlink-feed-registry`, `out-of-order-retryable`, `domain-separator-collision`, `gelato-unprotected-randomness` | the integration is in scope and the unchecked field decides value on the target chain | the integration is unused or the field is checked elsewhere — show where |

## Slither — typically noisy

Dismiss these as a group after reading one sampled hit, unless the promotion condition holds for a specific hit.

| Detector | Promote a hit when |
|---|---|
| `reentrancy-benign` | the late-written state feeds a price, share rate, or view that another contract reads during the callback (read-only reentrancy) |
| `reentrancy-events` | an on-chain or off-chain process acts on event order or values (bridge relayers, payout indexers) |
| `timestamp` | the comparison window is short enough for the block producer's timestamp freedom on the target chain to decide it, or the code tests timestamp equality |
| `low-level-calls` | the target can be an address with no code (the call succeeds silently) or the return value is unchecked — the latter also triggers `unchecked-lowlevel` |
| `assembly` | always read every assembly block by hand; the detector only lists them. Check memory safety, dirty upper bits, free-memory-pointer handling, and storage slot math |
| `solc-version`, `pragma` | the exact compiler in use appears in the Solidity bug list with conditions the code meets — route to `skill://smart-contract-audit/references/evm-compiler.md` |
| `naming-convention`, `too-many-digits`, `dead-code`, `cyclomatic-complexity`, `unindexed-event-address`, `erc20-indexed` | never a security finding; a name that contradicts behavior is an improper expression for `SYSTEM.md` |
| `events-maths`, `events-access` | an off-chain monitor in scope depends on the event |
| `costly-loop`, `reentrancy-unlimited-gas` | the loop length is attacker-growable — then treat as DoS under `calls-loop` |
| `constable-states`, `immutable-states`, `external-function`, `cache-array-length`, `var-read-using-this` | optimizations; a `GAS` item only with a measured delta |

## Slither printers and tools

| Command | Use |
|---|---|
| `slither . --print entry-points` | state-changing public/external functions — the threat model's entry-point list |
| `slither . --print function-summary` | per function: visibility, modifiers, state read and written, internal and external calls |
| `slither . --print vars-and-auth` | per function: state written and every condition on `msg.sender` (includes non-auth checks such as a `require` around `transferFrom(msg.sender, …)`) |
| `slither . --print modifiers` / `--print require` | which guards each function runs |
| `slither . --print not-pausable` | functions without `whenNotPaused` — compare against what the pause is supposed to stop |
| `slither . --print data-dependency` | which state and parameters each variable depends on — trace whether attacker input reaches a sink |
| `slither . --print variable-order` | storage order per contract — cross-check upgrade layouts |
| `slither . --print function-id` | selector table — look for collisions between a proxy and its implementation |
| `slither . --print call-graph` / `--print inheritance-graph` | dot files for orientation in large codebases |
| `slither-find-paths . Contract.function` | every entry point that reaches an internal function — the "unreachable" dismissal and the diff-review caller walk |
| `slither-check-upgradeability . <Impl> [--proxy-name <Proxy>] [--new-contract-name <ImplV2>]` | High checks: `order-vars-contracts`, `order-vars-proxy`, `function-id-collision`, `function-shadowing`, `missing-init-modifier`, `missing-calls`, `multiple-calls`, `variables-initialized`, `became-constant`, `were-constant`. Medium: `missing-variables`, `extra-vars-proxy`. Both implementations must compile in one tree for the V1/V2 comparison |
| `slither-check-erc . <Contract> --erc ERC20` | conformance of a token implementation; `--erc` also accepts `ERC721`, `ERC1155`, `ERC2612`, `ERC4626`, `ERC777`, `ERC1363`, among others |
| `slither-read-storage <address> --contract-name <Name> --rpc-url <url> --value` | read live storage of a verified deployment; `--storage-address <proxy>` reads the proxy's storage through the implementation's layout; `--block` needs an archive node |

Upgradeability checks pair with `skill://smart-contract-audit/references/upgradeability.md`.

## Aderyn

Aderyn has two buckets, High and Low. It covers some ground Slither does not — notably `unsafe-casting` (unchecked downcasts), `enumerable-loop-removal`, `storage-array-memory-edit`, and `function-selector-collision` — so read its High bucket even when Slither ran clean.

High-signal (aderyn 0.6.8 High bucket), with the same confirm/dismiss logic as the Slither twin:

| Detector | Slither twin or check |
|---|---|
| `arbitrary-transfer-from` | `arbitrary-send-erc20` |
| `unprotected-initializer` | confirm `initialize` is callable by anyone on the proxy before the deployer, or on the implementation, and grants a role that matters |
| `delegate-call-unchecked-address` | `controlled-delegatecall` |
| `eth-send-unchecked-address` | `arbitrary-send-eth` |
| `reentrancy-state-change` | `reentrancy-eth` / `reentrancy-no-eth` |
| `strict-equality-contract-balance` | `incorrect-equality` on a balance |
| `unsafe-casting` | confirm the source value can exceed the target type's range on a reachable path (amounts, timestamps cast to `uint32`/`uint40`, prices cast to `uint128`); `SafeCast` dismisses |
| `weak-randomness` | `weak-prng` |
| `msg-value-in-loop` | `msg-value-loop` |
| `abi-encode-packed-hash-collision` | `encode-packed-collision` |
| `tx-origin-used-for-auth` | `tx-origin` |
| `enumerable-loop-removal` | confirm `EnumerableSet.remove` runs while iterating the same set by index — removal swaps the last element in, so elements get skipped |
| `storage-array-memory-edit` | confirm a storage array passed to a function taking `memory` is edited there and the caller expects the edit to persist |
| `function-selector-collision` | confirm two callable functions on one dispatch surface (proxy + implementation, diamond facets) share a selector |
| `unchecked-low-level-call`, `unchecked-send` | `unchecked-lowlevel`, `unchecked-send` |
| `out-of-order-retryable` | Slither's twin; Arbitrum retryables in scope |

Low bucket — mostly noise, with these exceptions worth a read: `block-timestamp-deadline` (a swap passes `block.timestamp` as its deadline, so the deadline never binds — confirm the swap is exposed to delayed execution), `unchecked-return`, `return-bomb`, `delegatecall-in-loop`, `division-before-multiplication`, `ecrecover` (confirm the signature bytes, not the signer and nonce, key a uniqueness check — malleability then replays it), and `solmate-safe-transfer-lib` (confirm the token address can be one with no code — Solmate's `SafeTransferLib` does not check code size, so the transfer to an EOA "succeeds"). Dismiss `centralization-risk` under the privilege rule and record the trust assumption in `SYSTEM.md`.

Older aderyn releases use different names for some of these — 0.1.9 reports `send-ether-no-checks`, `unsafe-erc20-functions`, `zero-address-check`, `delegate-call-in-loop`, and has no `reentrancy-state-change`. Map by the detector's title in `aderyn registry`.
