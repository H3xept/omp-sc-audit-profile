---
name: onchain-forensics
description: Reviews deployed contracts and live incidents from chain state. Use when given a deployed address to check against an audit — bytecode verification, proxy implementation or admin, roles and owners on-chain (multisig, timelock), initialization, upgrade history, live parameters — or an exploit tx or incident to trace, attribute, and reproduce on a fork at the block before it.
---

# On-chain forensics

Chain state is the ground truth; the repo, the docs, and the audit report are claims about it. A gap between what the audit assumed and what is live is **drift**, and drift is a finding. Every result carries chain id, block number, and the command that produced it, so anyone can replay it at that block.

Two branches: **deployment review** (an address, a question about whether it is the audited system) and **incident analysis** (a tx hash, a question about what happened). A live incident runs [incident response](references/incident-response.md) first; containment outranks attribution.

## Setup

- RPC comes from `--rpc-url` or `ETH_RPC_URL`. The scripts need `cast` and `jq`; `bytecode-diff.sh` also needs `forge`.
- Historical work — `--block` reads, `cast run` on an old tx, `cast logs` back to deployment — needs an archive node; the commands below call it `$ARCHIVE_RPC`. Free endpoints vary. On 2026-10-02 `ethereum-rpc.publicnode.com` served latest state but rejected archive calls ("Archive requests require a personal token") and stalled on every `cast logs` query, while `rpc.mevblocker.io` served archive state and answered a 20M-block `cast logs` query in one second. Treat an empty result or a timeout on a historical call as a provider limit until proven otherwise.
- `0x` code at a well-known address means a wrong address or wrong chain before anything else. Take addresses from the deployment artifacts (`broadcast/*/run-latest.json`) or Etherscan, never from memory.
- Etherscan MCP tools carry what the RPC cannot: `get_contract_source` (verified source, compiler settings, and its `Implementation` field), `get_contract_creation` (creation tx and block — the `--from-block` for every log replay), `get_address_labels`, `get_token_transfers`, `get_internal_transactions`, `get_logs`.
- `cast storage <address>` with no slot prints the full storage layout with live values when the source is verified and `ETHERSCAN_API_KEY` is set. Run it outside a Foundry project; inside one it tries to compile the local sources first.

## Deployment review

Output is a drift table — item, audited assumption, live value at block N, verdict — written to the audit work directory. The review is done when every row has a verdict.

1. **Pin the target.** Record chain id and block (`cast block-number`). Map every audited contract to an address. Done when each in-scope contract has an address, a creation block from `get_contract_creation`, and the audited commit hash beside it.

2. **Classify each proxy.** Run [`scripts/proxy-info.sh`](scripts/proxy-info.sh) `<address> [--block N]`. It reads the EIP-1967 implementation, admin, and beacon slots, the legacy zOS and EIP-1822 slots, recognises EIP-1167 clones, EIP-7702 delegations, Safe proxies, and EIP-2535 diamonds, then prints the initializer state and the control chain. Who can upgrade depends on the type:

   | Type | Upgrader |
   | --- | --- |
   | transparent (admin slot set) | the admin; for OZ v5 that is a `ProxyAdmin` the proxy deployed itself, so its `owner()` is the real upgrader |
   | UUPS | whoever passes `_authorizeUpgrade` in the *current implementation* — an upgrade can remove upgradeability |
   | beacon | the beacon's owner, for every proxy on that beacon at once |
   | zOS `AdminUpgradeabilityProxy` | the zOS admin slot (USDC and EURC use this) |
   | EIP-1167 clone | nobody; the logic is fixed |
   | "no known proxy pattern" | unknown until `cast disassemble` shows whether `DELEGATECALL` reads a custom slot |

   Done when every address has a type, a logic address, and a named upgrader. Every later step runs against the logic address for code and the proxy address for storage.

3. **Verify the bytecode.** Check out the audited commit and build it with the deployed settings — compiler version, optimizer runs, `via_ir`, EVM version — taken from `get_contract_source`. Two routes:
   - [`scripts/bytecode-diff.sh`](scripts/bytecode-diff.sh) `<logic address> <ContractName | artifact.json> --root <repo>` diffs runtime code with the CBOR metadata stripped, labels every differing range as `immutable`, `library`, or `UNEXPECTED`, and prints each immutable's deployed value. Exit 0 means only expected differences.
   - `forge verify-bytecode <address> <path>:<Contract> --constructor-args ...` (run from the repo at the audited commit) checks creation and runtime code against the source verified on the block explorer (`--verifier`, Etherscan by default; needs `ETHERSCAN_API_KEY`), so it also covers constructor arguments. `--ignore creation|runtime` narrows it.

   Read the result:
   - Identical metadata hash: same sources and same settings.
   - Metadata differs but there are no `UNEXPECTED` ranges: comments, file paths, or other metadata inputs changed. Record it.
   - A length mismatch or many `UNEXPECTED` ranges on the same source usually means different settings. Rebuild with the deployed settings before you call it a finding.
   - `UNEXPECTED` ranges that survive a settings-matched build mean the deployed code is not the audited code.

   Done when every logic contract reports `0 unexpected` against the audited commit, or has a recorded drift row, and every immutable value matches the deployment script's constructor argument. Addresses sit in the low 20 bytes of the immutable's word.

4. **Map privileged roles.** For each role the audit relied on, resolve the live holder:
   - `owner()`, `pendingOwner()`, ProxyAdmin owner, Safe owners, threshold, modules, and guard, and timelock `getMinDelay()`: the `control:` section of `proxy-info.sh`, which follows `owner()` up to three hops.
   - AccessControl: [`scripts/roles.sh`](scripts/roles.sh) `<address> --from-block <creation block>` replays `RoleGranted` and `RoleRevoked` and reports whether the range covers deployment. It cross-checks every holder with live `hasRole`, classifies it as EOA or contract, and compares the count with `getRoleMemberCount` when the contract is enumerable. Exit 1 means events and state disagree: grants before `--from-block`, a grant path that emits no event, or a direct storage write. Roles with more than `--max-check` holders (blocklists) are listed without live checks. `--role <NAME|bytes32>` narrows the run to one role. Raise `--query-size` on providers that allow wide ranges; 2,000,000 worked on `rpc.mevblocker.io`.
   - Timelocks: run `roles.sh` on the timelock itself. `PROPOSER_ROLE`, `EXECUTOR_ROLE`, and `CANCELLER_ROLE` holders, plus `DEFAULT_ADMIN_ROLE` (OZ v5) or `TIMELOCK_ADMIN_ROLE` (OZ v4), define who controls the delay. `EXECUTOR_ROLE` granted to `address(0)` means anyone can execute.
   - Safe: each enabled module executes without owner signatures, so it is a holder in its own right. A guard can block every transaction. Threshold 1 means one key.

   Done when every privileged function in the audit resolves to a holder classified as EOA, EIP-7702-delegated EOA, Safe m-of-n, timelock with delay, or contract, and each contract holder is followed until the chain ends in keys. Weigh the result with `skill://smart-contract-audit/references/centralization-risk.md` and rate it with `skill://smart-contract-audit/references/methodology/severity.md`.

5. **Check initialization.** `proxy-info.sh` reads OZ v5's ERC-7201 slot `0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00` (= `cast index-erc7201 openzeppelin.storage.Initializable`) on both the proxy and the implementation. Proxy storage must show `_initialized >= 1`. Implementation storage should show initializers disabled (`type(uint64).max` in v5, `0xff` in v4). For OZ v4, find `_initialized` with `forge inspect <C> storageLayout` and read it with `cast storage`, because it sits in slot 0 only when `Initializable` is first in the layout. An implementation that can still be initialized, and that reaches `selfdestruct`, `delegatecall`, or UUPS upgrade logic, can be taken over. Done when every proxy and implementation has a recorded initialized version.

6. **Reconstruct the upgrade history.**
   ```bash
   cast logs --address <proxy> 'Upgraded(address)' --from-block <creation> --rpc-url "$ARCHIVE_RPC" --json
   cast logs --address <proxy> 'AdminChanged(address,address)' --from-block <creation> --rpc-url "$ARCHIVE_RPC"
   cast logs --address <proxy> 'BeaconUpgraded(address)' --from-block <creation> --rpc-url "$ARCHIVE_RPC"
   ```
   The topic0 is the same with or without `indexed`. The new implementation sits in `topics[1]` for OZ ERC1967 proxies and in `data` for zOS proxies. For a timelocked upgrader, read `CallScheduled` logs on the timelock to find queued upgrades that have not executed yet. Done when the last `Upgraded` matches the live implementation slot and each historical implementation is tied to an audited version or recorded as unaudited.

7. **Compare live parameters.** Read every value the audit assumed — fees, caps, oracle feeds and heartbeats, LTVs, delays, pause flags, allowlists — with `cast call` or the `cast storage` layout dump, at the pinned block. Feed freshness is `latestRoundData()` `updatedAt` against the block timestamp. Done when every assumption in the report or `.sc-audit/SYSTEM.md` has a live value and a match or drift verdict.

## Incident analysis

Output is an incident record: timeline, root cause at file:line with its checklist id, attacker graph, per-token loss, and a reproducing PoC.

1. **Freeze the facts.** `cast tx <hash> --json` and `cast receipt <hash> --json`: from, to, block, index in block, status, and timestamp (`cast age <block>`). Collect every exploit tx, not just the first: attackers repeat across pools and chains (`get_transactions` on the attacker EOA). Done when each exploit tx has a block and an index, and the incident window (first to last tx) is bounded.

2. **Trace.** `cast run <hash> --rpc-url "$ARCHIVE_RPC"` replays every earlier tx in the block, then the target, and prints a decoded call tree. Verified contracts decode through `ETHERSCAN_API_KEY`.
   - `--quick` executes on the previous block's state and skips the earlier txs in the same block. It is faster, but the result can differ from live when the attack depends on a same-block setup tx or a sandwich. Confirm on a full run before relying on it. A full run fetches state for every earlier tx in the block, and on a free endpoint it timed out mid-block (`database error: failed to get storage`). That error is a provider limit, not a revert; rerun on a dedicated archive endpoint.
   - Name addresses with `-l <address>:<name>` (repeatable) and decode internal functions with `--decode-internal`.
   - `--with-local-artifacts` decodes against the victim's local build.
   - `-d` opens the tx in the debugger for opcode-level stepping through the frame that breaks the invariant.

   Done when every call the attacker contract makes is labelled and the first state change that violates an invariant is pinned to a call frame.

3. **Decode what is unverified.** `cast 4byte <selector>`, `cast 4byte-calldata <calldata>`, `cast 4byte-event <topic0>`, `cast decode-error <data>`. Signature databases hold collisions, so confirm a match against the target's ABI (`get_contract_abi`) or bytecode. For a known signature use `cast decode-calldata '<sig>' <calldata>`. Attacker contracts are almost never verified: `cast selectors <bytecode>` lists their dispatch table and `cast disassemble` shows the rest. Done when every selector in the trace has a name or is recorded as unresolved.

4. **Trace value.** Pull `Transfer` logs (topic0 `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef`) from the receipt, add native ETH from `get_internal_transactions` by tx hash, and build a net-delta table of address × token. Flash loans net to zero inside the tx. What remains is the profit. Done when, per token, the protocol's net loss equals the sum of the attacker-side gains plus fees and MEV payments, and every residual is explained.

5. **Attribute.** The attacker EOA is `tx.from`. The attacker contract is `tx.to` or a contract the EOA created earlier (`get_contract_creation`). Funding is the EOA's earliest inbound transfers (`get_transactions`, `get_internal_transactions`, `get_token_transfers`, with `get_address_labels` for mixer, bridge, or exchange labels). Exits are every outbound transfer after the exploit. Done when the graph runs funding source → EOA → attacker contracts → exploit txs → exit addresses, with a tx hash on every edge.

6. **Reproduce on a fork.** Build the PoC from `skill://test-foundry/references/exploit-poc.md`. Fork at `block - 1` with `vm.createSelectFork(rpc, block - 1)`. When the exploit depends on earlier txs in its own block, fork with `vm.createSelectFork(rpc, txHash)` instead, which replays the block's earlier txs before the exploit. Done when the PoC reproduces the observed per-token loss to within rounding, and fails once the root-cause fix is applied to the forked code (`vm.etch` the patched runtime).

7. **Write it up.** Link the root cause to the vulnerable line in the audited source and to its `SOL-` or `AUD-` checklist id. Mark anything not observed in a trace, log, or PoC as `[INFERENCE]`. Rate it with `skill://smart-contract-audit/references/methodology/severity.md`. Done when every timeline entry cites a tx hash and every loss figure traces back to step 4's table.
