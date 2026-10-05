# Threat model

The procedure a solo auditor runs before hunting. It turns the code into a map of what holds value, who can touch it, through which doors, under which assumptions, and which truths must never break — then ranks the doors so the hunt starts where loss is likeliest. The pipeline's MAP phase builds the same picture as JSON (`skill://audit-pipeline/assets/prompts/map.md`); this file is the hand-run version and the reasoning behind each field.

Output lands in the audit work directory. Purpose, components, actors, trust boundaries, and invariants go into `.sc-audit/SYSTEM.md` (the durable artifact described in `AGENTS.md`); the entry-point table and the hunt order go into `.sc-audit/threat-model.md`, which belongs to this engagement only. With a prior `SYSTEM.md`, read it first and treat every claim in it as a hypothesis the current code must re-earn; record each divergence as drift.

The threat model produces no findings and no severities. Anything that looks exploitable becomes a hypothesis in Step 6.

## Step 0 — Pin the target

Record the commit hash, the in-scope file list, the compiler version and EVM target from `foundry.toml` or the build config, the chains the code deploys to, and every document the team supplied (README, spec, prior audits and their acknowledged issues).

**Done when** the commit hash and the in-scope file list are written down and every later claim can be read as "true at this commit".

## Step 1 — Purpose and asset inventory

Write the purpose as one sentence with three slots: who puts value in, what they get back, how the protocol or its operators earn. "Lenders deposit USDC for interest-bearing shares; borrowers post ETH collateral to borrow USDC; the protocol keeps a reserve factor of interest." A purpose you cannot fit in that sentence means the scope has more than one system — model each.

Then list every asset the system holds or controls:

| Asset | Held at | Tracked by (storage variable) | Leaves through |
|---|---|---|---|
| ERC-20 / ETH / NFT balances | contract address, strategy, external protocol position | the accounting variable that should equal it | every function that transfers it out |
| Liabilities: shares, debt tokens, receipts, claimable rewards | ledger mapping | `totalSupply`, per-user mapping | redeem, burn, claim |
| Allowances users grant to the protocol | user's token allowance | none — an asset the protocol can spend | every `transferFrom` whose `from` is not `msg.sender` |
| Allowances the protocol grants out | protocol's allowance on a router or strategy | approve sites | every call to the approved spender |
| Privileged roles | role mapping, `owner` slot, proxy admin slot | role setters | grant, transfer, renounce, upgrade |
| Signatures and nonces | off-chain, nonce mapping | nonce/used-hash mapping | every signature verification |

Find the rows mechanically: grep the scope for `transfer(`, `transferFrom(`, `safeTransfer`, `call{value:`, `_mint(`, `_burn(`, `approve(`, `permit(`, and `delegatecall`. Each hit is a value movement and belongs to a row.

**Done when** every value-moving call site in scope maps to one row of the inventory, and every row names the storage variable that is supposed to track it (or states that none does — itself worth a hypothesis).

## Step 2 — Actor inventory

List every actor, how one becomes that actor, and what the actor can move. Start from this roster and drop the ones the system does not have:

| Actor | Becomes one by | Typical capabilities |
|---|---|---|
| Anonymous user | anyone, any contract | every permissionless entry point; deploys contracts that receive callbacks |
| Liquidity provider / depositor | depositing | redeem own position; donate to the pool |
| Borrower | posting collateral | borrow, repay, withdraw collateral; choose when to be liquidatable |
| Liquidator | anyone, usually | seize collateral at a discount; choose amount and timing |
| Keeper / relayer | role grant or permissionless | trigger rebalances, harvests, settlements; choose ordering and timing; supply calldata |
| Oracle | external feed | set the price every valuation reads |
| Admin roles (owner, guardian, manager, upgrader) | role grant | parameters, pause, upgrade, sweep — read each function, not the role name |
| Governance | token holdings or delegation | everything the timelock executes; voting power may be borrowable |
| External protocols | integration | return values, callbacks, pause, upgrade, loss events |
| MEV searcher | anyone | reorder, front-run, back-run, sandwich within a block; flash-borrow capital |
| Validator / sequencer | block production | timestamp within bounds, inclusion, ordering; on an L2, sequencer downtime and private ordering |

For each present actor, write what they can move in the asset inventory's terms: "Liquidator: transfers borrower collateral to self at `price * (1 + bonus)`, bounded by `closeFactor` of the debt."

Mechanical cross-check: `slither . --print vars-and-auth` lists, per function, the state variables written and every condition that mentions `msg.sender`. That column also shows non-auth checks such as `require(token.transferFrom(msg.sender, ...))`, so read each condition before calling it a guard. `slither . --print modifiers` lists the modifiers each function runs.

**Done when** every modifier and every `msg.sender` check in scope maps to an actor, and every permissionless state-changing function is reachable by at least the anonymous user row.

## Step 3 — Entry-point enumeration

Generate the raw list with Slither (printers verified on slither 0.11.5):

```bash
slither . --print entry-points       # state-changing public/external functions per contract
slither . --print function-summary   # per function: visibility, modifiers, state read/written, internal and external calls
slither . --print vars-and-auth      # per function: state written, conditions on msg.sender
```

Add what the printers do not list as entry points but an attacker can still reach: `receive` and `fallback`; callback hooks the system exposes (`onERC721Received`, `onERC1155Received`, `uniswapV3SwapCallback`, flash-loan `onFlashLoan`/`executeOperation`, LayerZero/CCIP receivers); functions reachable through `delegatecall` or a multicall/batch router; and `view` functions other contracts consume for pricing (read-only reentrancy targets).

Fill one row per entry point:

| Function | Caller (actor) | Guard (file:line) | State written | Value moved (asset, direction, amount source) | External calls (target, before/after state write) |
|---|---|---|---|---|---|

The last column decides most reentrancy and callback questions: an external call to a target the caller controls, placed before the write that settles the caller's claim, is a hypothesis. `slither-find-paths . Contract.function` lists every internal path that reaches a given function — use it to see which entry points reach a shared internal helper.

**Done when** the table has a row for every `entry-points` printer row plus every addition above, and every cell is filled or reads "none".

## Step 4 — Trust boundaries and assumptions

A trust boundary is any place where the system acts on something it does not control. For each external call target from Step 3, each privileged actor from Step 2, and each input from off-chain, write:

- **Trusted to:** what the system assumes (the feed is fresh and unmanipulable at the size of positions; the token moves exactly the amount requested; the admin sets fees under 10%).
- **If it misbehaves:** the concrete consequence, in asset-inventory terms.
- **Enforced by:** the file and line that enforces the assumption, or "documented only", or "unstated".

Boundaries that recur, with what to pin down:

- **Oracles:** spot price from a pool (manipulable within one transaction) versus TWAP versus push feed; heartbeat and deviation threshold per feed and chain; decimals; behavior on a negative, zero, or stale answer; sequencer-uptime handling on L2s.
- **Tokens:** which tokens are in scope and which non-standard behaviors each has. Classify each behavior with the IDs and dispositions in `skill://smart-contract-audit/references/weird-erc20.md` rather than re-deriving them.
- **Admin and governance:** each privileged function's actual power, the timelock and its delay, whether the docs restrict the role. Severity treatment of admin powers lives in `skill://smart-contract-audit/references/methodology/severity.md` (Privilege rule).
- **External protocols:** what happens when the integrated protocol pauses, upgrades, takes a loss, or returns less than asked.
- **Cross-chain and off-chain:** message authenticity, replay across chains, ordering, and what a relayer or signer can choose.

**Done when** every external call site from Step 3 sits under exactly one boundary, and every assumption is labelled "enforced at file:line", "documented only", or "unstated". The "documented only" and "unstated" labels are the hunt's richest seams.

## Step 5 — Invariants as falsifiable sentences

Write each invariant as a sentence about the protocol that one reachable state can falsify. Give it an id (`INV-001`, matching the pipeline), the state variables it relates, and the functions that can break it. Cover each family:

| Family | Shape | Example |
|---|---|---|
| Conservation | what goes in equals what is recorded | `sum(balanceOf[u]) == totalSupply` after every call |
| Solvency | assets cover liabilities | `asset.balanceOf(vault) >= convertToAssets(totalSupply)` at all times outside a callback |
| Monotonicity | a quantity only moves one way | the share price never decreases except through a recorded loss event; `nonce[u]` only increases |
| Access | a state change implies an authorized caller | `feeBps` changes only in a transaction from `owner`; no call by a non-owner changes any role mapping |
| Liveness | an exit always exists | a user with shares can always redeem them for at least `previewRedeem` assets when not paused |
| Consistency | views agree with actions | `previewDeposit(a)` equals the shares `deposit(a)` mints in the same block |

Phrase each as "for every reachable state" or "for every call", never as a restatement of a line of code. Where the team documented invariants, adopt their wording and mark the source. Property shapes for fuzzers and Foundry invariant tests live in `skill://fuzz-echidna-medusa/references/property-catalog.md`.

**Done when** every asset row has at least one conservation or solvency invariant, every privileged function has an access invariant, every exit path has a liveness invariant, and each invariant names a counterexample state that would falsify it.

## Step 6 — Attack-surface ranking

Rank entry points to set hunt order. Order by these keys, highest first; break ties with the next key:

1. **Value reach:** moves principal of other users > moves the caller's own funds > moves yield or fees > moves nothing.
2. **Caller:** permissionless > permissionless with capital > role-gated.
3. **Control handed out:** external call to a caller-chosen target or token, or a callback, before state settles > external call to a fixed trusted target > none.
4. **Arithmetic and shared state:** share/price math, rounding, or state that three or more entry points write > simple bookkeeping.
5. **Novelty:** custom code > a modified fork of audited code > an unmodified audited library.
6. **Assumption weakness:** touches a "documented only" or "unstated" boundary from Step 4.

For the top entries, write the first hypothesis to test as "`<function>` can break `INV-xxx` when `<condition>`", and name the playbook from `skill://smart-contract-audit/references/playbooks/` and the checklist files to load for it.

**Done when** every entry-point row has a rank, the top five carry a hypothesis that names an invariant, and the checklist files to load are listed.

## Worked example — toy vault

A 50-line share vault: `deposit(assets)` mints shares at `assets * totalShares / totalAssets()` (1:1 when empty), `redeem(shares)` pays `shares * totalAssets() / totalShares` minus a fee to the owner, `totalAssets()` returns `asset.balanceOf(address(this))`, and the owner sets `feeBps` and `strategy`.

**Step 1.** Purpose: "Depositors put in `asset` for pro-rata shares; the owner earns a redemption fee." Assets: the vault's `asset` balance (tracked by nothing — `totalAssets()` reads the live balance), shares (`totalShares`, `sharesOf`), the users' allowances to the vault (spent only with `from = msg.sender`), the `owner` slot.

**Step 2.** Actors: anonymous depositor, the owner, the asset token. `vars-and-auth` on the toy shows `setFee` and `setStrategy` gated by `msg.sender == owner`, and lists `deposit` with the condition `asset.transferFrom(msg.sender, address(this), assets)` — a transfer check, not a guard; `deposit` is permissionless.

**Step 3.**

| Function | Caller | Guard | State written | Value moved | External calls |
|---|---|---|---|---|---|
| `deposit(uint256)` | anyone | none | `sharesOf`, `totalShares` | asset in, amount = argument | `asset.balanceOf` (before writes), `asset.transferFrom` (after writes) |
| `redeem(uint256)` | share holder | `sharesOf -= shares` underflow | `sharesOf`, `totalShares` | asset out to caller and to owner, amount from share math | `asset.balanceOf` (before writes), two `asset.transfer` (after writes) |
| `setFee(uint256)` | owner | `onlyOwner` | `feeBps` | none | none |
| `setStrategy(address)` | owner | `onlyOwner` | `strategy` | none | none |

**Step 4.** Token boundary: the vault assumes the asset moves the exact amount and has no hooks — unstated, so catalog rows B1 (fee on transfer) and E1 (hooks) apply if such tokens are in scope. Admin boundary: `feeBps` has no upper bound — "unstated"; above 10 000 the `assets - fee` subtraction reverts and freezes every redemption, which is out of model for an honest admin unless the docs promise a cap. `strategy` is written and never read: an improper expression for `SYSTEM.md`, not a finding.

**Step 5.** INV-001 (solvency): for every depositor `u`, absent a loss event, `asset.balanceOf(vault) * sharesOf[u] / totalShares` is at least what `u` deposited, minus fees and at most one wei of rounding per operation. INV-002 (conservation): `sum(sharesOf) == totalShares`. INV-003 (access): only `owner` changes `feeBps`. INV-004 (liveness): any holder can redeem all their shares while `feeBps <= 10 000`.

**Step 6.** Rank 1: `deposit` — permissionless, share math against a balance anyone can inflate by direct transfer. Hypothesis: "`deposit` breaks INV-001 when an attacker deposits 1 wei into the empty vault, donates a large balance, and the victim's deposit rounds to zero shares." Load the vaults playbook, `defi.md`, and `attacker-s-mindset.md`. Rank 2: `redeem` — rounding of `fee` on an already-rounded `assets`, and transfers after writes. On this toy (slither 0.11.5), `reentrancy-eth` and `reentrancy-no-eth` stay silent because the share writes precede the calls, while `reentrancy-balance` and `divide-before-multiply` both fire on `redeem`; neither the silence nor the hits settle anything until triaged (`skill://smart-contract-audit/references/methodology/static-analysis-triage.md`). Ranks 3–4: the two owner setters.

## Diff and fix review mode

Use this mode to audit a pull request, an upgrade, or a fix for a reported finding. The question changes from "what can break" to "what did this change break, and did it fix what it claims".

1. **Collect the change.** `git diff <base>..<head> -- '*.sol'` plus the commit messages and the finding or issue the change claims to address. For upgradeable contracts, dump `forge inspect <Contract> storage-layout --json` at both commits and diff them; when both implementations compile in one tree (a `VaultV1` beside a `VaultV2`, or the old file copied in under a new name), also run `slither-check-upgradeability . <OldImpl> --new-contract-name <NewImpl> --proxy-name <Proxy>`. **Done when** each changed hunk is listed with its file and line range, and the layout diff is recorded.
2. **Tie each hunk to invariants.** Load the prior `SYSTEM.md`; for each hunk, name the invariants it touches or mark it non-semantic (comment, rename, event-only). A hunk that touches no listed invariant either adds a new one (write it) or reveals a gap in the model. **Done when** every hunk carries invariant ids or the non-semantic mark.
3. **Walk every caller.** For each changed function or modifier, list every caller: `slither-find-paths . <Contract>.<function>` for internal paths, a grep for the name and selector across the repo, and integrators outside the repo that the docs name. A changed return value, revert condition, rounding direction, or event shape breaks callers the diff does not show. **Done when** every caller is listed and each is marked unaffected or carried into a hypothesis.
4. **Test the fix for completeness.** A fix is complete when it removes the root cause, not one path to it. Look for sibling instances of the same pattern in other functions; other entry points that reach the same state (fixed `withdraw`, unfixed `redeem` or `transfer`); the same guard bypassed through a batch, multicall, or callback; and new checks that read attacker-controlled values. **Done when** each sibling and alternative path is listed and marked covered or uncovered.
5. **Hunt regressions.** New external calls (control handed out), new `require`s on exit paths (liveness), changed rounding direction, changed storage order or types, reordered initializers or a new `reinitializer` version, and changes to anything a view-function integrator reads. **Done when** each category is checked against the diff.
6. **Re-run the proof.** Run the original PoC against the fixed code: it must now fail, and fail for the root-cause reason — the revert or assertion the fix introduced, never a broken setup. Then vary it: other amounts, other orderings, the alternative entry points from step 4. Run the full test suite and any invariant campaign on the new commit. PoC conventions live in `skill://test-foundry/references/exploit-poc.md`. **Done when** the original PoC fails with the expected reason, each variant's result is recorded, and the suite is green or its failures are explained.

Report an incomplete fix as a new finding that names the original, the path the fix missed, and a PoC for that path.
