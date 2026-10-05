# Weird-ERC20 behavior catalog

A taxonomy of non-standard and adversarial ERC-20 behaviors, each with real
token examples, an applicability predicate, the property to assert, and a test
fixture. IDs (A1…J4) are stable — keep them in every artifact so exclusions
stay traceable.

Confidence flags: `[C]` confirmed · `[K]` established practice · `[?]`
unverified lead. `[?]` items NEVER become required compatibility claims —
disposition them DEFERRED_UNVERIFIED unless the target deployment justifies
verifying them first.

Two uses, one matrix:

- **Audit** — the matrix is the token-integration coverage record. A reachable
  row whose oracle fails on the current code is a finding; cite the catalog ID
  next to any `SOL-Token-*` item it matches. Persist the matrix at
  `.sc-audit/weird-tokens.md`.
- **Test hardening** — the matrix drives which mocks and cases get written.
  Persist it at `test/WEIRD-TOKENS.md`.

## Pipeline (three artifacts)

```
this catalog (what tokens can do)
  → token-surface inventory (what THIS repo does with tokens; built during scoping/MAP)
  → disposition matrix (what must be tested and under which policy;
    test-design output, implementer input — see Matrix lifecycle below)
```

The deliverable is never "a list of mocks" — it is the matrix; the mock list
falls out mechanically. One row per catalog ID, no omissions. Closed
disposition set:

- `TEST` — reachable; gets cases (with a policy, below)
- `NOT_APPLICABLE` — the repo never exercises the capability (evidence: cite
  code, e.g. "no permit call sites")
- `SUPPORTED_BY_TRUST_ASSUMPTION` — reachable but excluded by an explicit,
  user-confirmed trust statement (e.g. "issuer will not enable USDT's latent
  fee"); recorded in the trust-assumptions section, still gets a cheap
  containment smoke test where one exists
- `OUT_OF_SCOPE` — outside the requested scope (e.g. off-chain indexer
  concerns, undeclared chains)
- `DEFERRED_UNVERIFIED` — `[?]` leads not worth verifying for this target

Every non-TEST row needs evidence citing repo code or a user decision. Grep is
discovery, not proof — the inventory must trace actual custody paths (entry
point → transfer primitive → accounting basis → state/call order).

## Policy adjudication (ask the user)

For behavior families where the repo's surface makes BOTH readings viable, the
support decision is the **maintainer's, not the auditor's or test designer's**.
First read the protocol's documented token scope (README, contest "weird
tokens" statement, listing policy). For each reachable family the documents
leave open, after the token-surface inventory exists and before designing
tests, ask the user one question per applicable family (batch them; give a
recommendation and the cost of each option):

- **SUPPORT** — the protocol handles the behavior correctly → correctness
  oracles (measured-delta accounting, sentinel semantics honored, shares
  bookkeeping, …)
- **REJECT-SAFE** — the protocol need not support it, but a fault must be
  contained → containment oracles: atomic revert or clean failure, no internal
  credit without assets, no corruption of unrelated positions, no stranded
  funds beyond the offending token itself
- **TRUST-ASSUMPTION** — out of threat model by explicit statement → documented
  + containment smoke test

There is no "no test" policy for a reachable behavior: SUPPORT and REJECT-SAFE
both produce tests; they differ in which oracle. Record each answer in the
matrix (`policy` column, provenance "user-adjudicated <date>" or
"documented: <file:line>") and in the trust-assumptions section.

In an audit, a TRUST-ASSUMPTION row is itself reportable when token listing is
permissionless: the assumption is not enforced by code. Severity follows
`skill://smart-contract-audit/references/methodology/severity.md`.

Families that typically warrant a question (only ask when reachable):
fee-on-transfer (B1, D8) · rebasing/balance drift (B3–B6) · `uint256.max`
sentinel à la cUSDCv3 (B2) · hook/callback tokens (E1–E3) · blocklist/pause
liveness (D4, D5) · permit variants (C9) · supported decimals range (G4, G5) ·
chain-specific behaviors per declared deployment chains (F2, J1–J4).
Behaviors that are never "supportable" (outright buggy/malicious, section I;
phantom functions A6) get no question — only containment.

## Catalog

Fixture column: a bare name = `d-xo/weird-erc20 src/<Name>.sol`; RECIPE = build
a minimal local mock (recipes below); `std` = any standard OZ-style mock.
Suite column: `U` = unit/integration case (`skill://test-foundry`), `S` =
stateful/invariant suite (`skill://recon-suite` + `skill://fuzz-echidna-medusa`),
`T` = table-test boundary rows.

### A — Return values & failure signalling

| ID | Behavior (example) | Applies when | Oracle | Fixture | Conf | Suite |
|---|---|---|---|---|---|---|
| A1 | No return value (USDT) | any transfer/approve call site | call succeeds via wrapper; movement AND accounting agree | MissingReturns | C | U |
| A2 | bool on some methods only (BNB: transfer returns nothing, transferFrom returns true) | uses both transfer and transferFrom | each path handled per its own shape (A1 for the bare one) | RECIPE (trivial) | C | U |
| A3 | Declares bool, returns false ON SUCCESS (Tether Gold) | any transfer call site | decide + document the wrapper trade-off: A3 (false=ok) and A4 (false=failure) are irreconcilable — empty returndata (A1) is distinguishable from both | ReturnsFalse (verify: false-on-success vs false-on-failure) | C | U |
| A4 | Returns false instead of reverting (ZRX, BAT) | any transfer call site | false return treated as failure; no credit | NoRevert (verify semantics) | C | U |
| A5 | Reverts instead of returning false (OZ-style) | batch loops / branch-on-false designs | one bad recipient doesn't brick the batch (or documented that it does) | std | K | U |
| A6 | Phantom functions: non-reverting fallback swallows permit/any selector (WETH9) | any permit / optional-extension call | from a DIFFERING pre-state (zero or wrong allowance), assert allowance equals the signed value and the nonce advanced — a pre-existing matching allowance masks the no-op (the Multichain exploit shape) | RECIPE | C | U |
| A7 | Unbounded gas on transfer | fixed-gas call sites, batch loops | loop completes or fails cleanly at documented gas bound | RECIPE (gas-burner hook) | K | U |

### B — Amount moved ≠ amount requested

| ID | Behavior | Applies when | Oracle (SUPPORT / REJECT-SAFE) | Fixture | Conf | Suite |
|---|---|---|---|---|---|---|
| B1 | Fee on transfer (STA, PAXG; USDT latent) | protocol pulls or pushes tokens and keeps balance accounting (a correct delta-crediting path still needs the regression test) | credit == measured delta / atomic revert, zero credit | TransferFee | C | U+S |
| B2 | `uint256.max` = whole balance (cUSDCv3) | accepts user-supplied transfer amounts | sentinel honored: credit == actual moved / sentinel rejected before transfer | RECIPE | C | U |
| B3 | Share rounding: full balance short 1–2 wei (stETH) | "transfer entire balance", exact repayment | shares bookkeeping or re-read balance / reject rebasing class | RECIPE (rebasing) | C | U+S |
| B4 | Balance changes with no transfer — rebase/airdrop (AMPL, aTokens) | any cached balance or exact conservation | invariants hold across rebase between ops / class rejected + containment | RECIPE (rebasing) | C | S |
| B5 | Reflection: others' trades move your balance | same as B4 | same oracles as B4, but the trigger differs: a THIRD PARTY's transfer must move the protocol's balance — an explicit `rebase()` control does not exercise this | RECIPE (reflection: fee redistributed to holders on transfer) | K | S |
| B6 | Negative rebase — balances go DOWN | solvency checks, collateral accounting | solvency invariant survives contraction / containment | RECIPE (rebasing, negative) | K | S |

Balance-delta (`after - before`) crediting is the B1 mitigation but is itself
unsafe under B4/B5 and mid-flow donations — the matrix must say which
assumption each custody path relies on.

### C — Allowance & permit

| ID | Behavior | Applies when | Oracle | Fixture | Conf | Suite |
|---|---|---|---|---|---|---|
| C1 | Can't overwrite non-zero allowance (USDT) | protocol calls approve more than once | forceApprove pattern used; second approve succeeds | Approval | C | U |
| C2 | Max allowance never decremented (DAI) | infers spend from allowance diff | no allowance-diff inference | std + max approve | C | U |
| C3 | uint96 cap, silent clamp on max (UNI, COMP) | approve/transfer above uint96 | boundary at uint96 max / max+1 behaves per design | Uint96 | C | U+T |
| C4 | transferFrom(self) conventions differ (DSToken vs OZ) | protocol moves its own tokens via transferFrom | works under both conventions or one documented | TransferFromSelf | C | U |
| C5 | Revert on approve(0 addr) | approves derived addresses | derived spender never zero, or clean failure | ApprovalToZeroAddress | C | U |
| C6 | Revert on approve(spender, 0) (BNB) | forceApprove/reset-to-zero pattern | mutually hostile with C1 — document which family is supported | ApprovalWithZeroValue | C | U |
| C7 | approve requires balance | pre-fund approval flows | flow order tolerates it or class rejected | RECIPE (trivial) | C | U |
| C8 | No Approval event | off-chain allowance tracking in scope | OUT_OF_SCOPE unless indexers in scope | — | C | — |
| C9 | Non-EIP-2612 permit (DAI-style) | protocol calls permit | both permit shapes or one documented + safe failure on other | DaiPermit | C | U |
| C10 | permit is a silent no-op | = A6 | = A6 | RECIPE (A6) | C | U |
| C11 | DOMAIN_SEPARATOR cached at deploy | relies on cross-fork replay protection | DEFERRED_UNVERIFIED by default | — | ? | — |

### D — Transfers that revert or are blocked

| ID | Behavior | Applies when | Oracle (SUPPORT / REJECT-SAFE) | Fixture | Conf | Suite |
|---|---|---|---|---|---|---|
| D1 | Revert on zero-value transfer (LEND) | computed amounts can be 0 | zero-amount path skips transfer / loop survives | RevertZero | C | U |
| D2 | Revert on transfer to 0 addr | burn-by-zero-send | no zero-address sends, or intended burns use burn() | RevertToZero | C | U |
| D3 | Refuse self/token-address transfers | router parks tokens at token addr; self-transfer tests | no such parking, or clean failure | RECIPE (trivial) | C | U |
| D4 | Admin blocklist (USDC, USDT) | protocol contract can be listed; users can | deposit-then-blocklisted-withdraw: position recoverable or loss contained to that token | BlockList | C | S |
| D5 | Pausable (USDC, USDT) | liveness across pause | ops fail cleanly while paused; state consistent after unpause | Pausable | C | S |
| D6 | Allowlist/KYC-gated (ERC-1404) | pool must hold the token | usually SUPPORTED_BY_TRUST_ASSUMPTION or policy REJECT-SAFE | RECIPE if TEST | C | S |
| D7 | Anti-bot: max tx size, per-block cooldown, contract-caller rejection | flash loans, batches, two-transfers-per-block | usually REJECT-SAFE: containment | RECIPE if TEST | K | S |
| D8 | Mutable/asymmetric/address-dependent fee (honeypot switch) | B1 is reachable and positions span multiple ops | fee re-measured or bounded per op / containment when fee → 100% between ops | RECIPE (setFee) | K | S |

### E — Reentrancy, hooks & callbacks

| ID | Behavior | Applies when | Oracle | Fixture | Conf | Suite |
|---|---|---|---|---|---|---|
| E1 | ERC-777 hooks: counterparty gets control mid-transfer (imBTC) | any external token call (correct CEI ordering still needs the regression test) | callback attempts the forbidden read/action and PROVABLY fails (assert the attempt happened — no reentrancy theater) | Reentrant | C | U+S |
| E2 | Custom-fallback abuse: token calls arbitrary target as itself (ATN) | trusts `src == token` anywhere | REJECT-SAFE: containment | RECIPE if TEST | C | U |
| E3 | ERC-1363/677 transferAndCall | same as E1, fixed callback | as E1 | RECIPE (thin) | C | U |
| E4 | balanceOf gas-heavy or reverting | health checks, liquidations call balanceOf | liquidation path survives or fails cleanly | RECIPE (revert/gas toggle) | K | U |

Read-only reentrancy (E1 corollary): if the repo exposes price/state getters,
the callback must attempt to observe mid-update state — guards on mutating
functions alone don't close it.

### F — Token identity & accounting model

| ID | Behavior | Applies when | Oracle | Fixture | Conf | Suite |
|---|---|---|---|---|---|---|
| F1 | Double entry point: two addresses, one ledger (TUSD; Compound sweepToken drain) | rescue/sweep fns, `token != underlying` checks, allowlists keyed by address | sweep via alias address leaves underlying ledger UNCHANGED (before/after invariant, not address compare) | RECIPE (two facades) | C | U |
| F2 | Native currency as ERC-20 (Celo, Polygon POL) | declared chains have one AND protocol takes msg.value | value not creditable twice | RECIPE if chain-relevant | C | U |
| F3 | Same asset, many bridged addresses | allowlist/oracle mapping per chain | config review, not a mock | — | K | — |
| F4 | Upgradeable (USDC, USDT) | any long-lived position | behavior-change-under-you: usually TRUST-ASSUMPTION + monitoring note | Upgradable | C | S |
| F5 | Flash-mintable / extreme balances (DAI) | two distinct properties: (a) math at extreme balances — applies wherever amounts are user-scaled; (b) tx-local supply/rented governance weight — applies only if totalSupply or token voting weight is read | (a) math survives near-uint256 balances (deal() extremes; table rows); (b) decisions don't trust intra-tx supply/weight | (a) std + deal; (b) RECIPE (flashMint) if reachable | C | S+T |
| F6 | ERC-404 hybrids | arbitrary-token acceptance | DEFERRED_UNVERIFIED | — | ? | — |

### G — Metadata & introspection

| ID | Behavior | Applies when | Oracle | Fixture | Conf | Suite |
|---|---|---|---|---|---|---|
| G1 | bytes32 name/symbol (MKR) | on-chain reads of metadata | staticcall + length sniff, or clean rejection at listing | Bytes32Metadata | C | U |
| G2 | Metadata missing/misnamed (ICX) | decimals() hard dependency (esp. constructors) | fallback or specified rejection; never a constructor hard-dep | RECIPE (trivial) | C | U |
| G3 | decimals returns uint256 | decodes as uint8 | bounded decode or rejection | RECIPE (trivial) | C | U |
| G4 | Low decimals — USDC 6, GUSD 2 | fixed-point scaling, dust thresholds | rounding direction matches the spec per operation (spec-derived, not "favor the protocol"); no value minted by rounding; table rows at 0/2/6/8 | LowDecimals | C | T |
| G5 | High decimals — YAM-V2 24 | `amount * 1e18` style scaling | no intermediate overflow (revert-liveness) at 24 | HighDecimals | C | T |
| G6 | Mutable decimals via upgrade | cached decimals | DEFERRED_UNVERIFIED (`[?]` rule) unless verified for a held token; then TRUST-ASSUMPTION or re-read | — | ? | — |
| G7 | Code injection via name/symbol | frontends/subgraphs in scope | OUT_OF_SCOPE for Solidity-only repos | — | C | — |

### H, I, J — prose-defaulted sections

These sections have no per-ID table; their matrix rows cite the section rule
below as evidence and take the stated default disposition unless the surface
inventory contradicts it. That still means one matrix row per ID — H1–H4,
I1–I14 (as one block row "I1–I14" is acceptable), J1a/J1b, J2–J4.

**H — Events (H1–H4).** Off-chain accounting concerns. Default OUT_OF_SCOPE
unless indexers/subgraphs are part of the requested scope; if in scope, oracle:
balance-derived and event-derived accounting reconcile or the divergence is
documented.

**I — Outright buggy & malicious (I1–I14: BEC overflow, missing allowance
checks, fake burns, honeypots…).** Never SUPPORT; no user question beyond the
arbitrary-token acceptance policy itself. If the API accepts arbitrary token
addresses: disposition TEST with policy REJECT-SAFE, covered by the bounded
behavioral classes (A–G mocks + E1/D8) — a fully malicious token can lie,
reenter, and burn gas arbitrarily, so state explicitly that arbitrary-code
safety is NOT claimed. Otherwise NOT_APPLICABLE.

**J — Chain-specific.** Disposition per the repo's DECLARED deployment chains
only; undeclared chains → OUT_OF_SCOPE.
- **J1a** USDT-on-Tron returns false on success `[?]` → DEFERRED_UNVERIFIED
  even when Tron is declared, unless verified first (mechanism = A3 or A1;
  mitigation differs).
- **J1b** Tron OUT_OF_ENERGY / historical TVM divergence `[C]` → off-chain
  reconciliation concern; OUT_OF_SCOPE for Solidity-only repos even with Tron
  declared (note it in the trust-assumptions section), TEST only if
  broadcast/reconcile logic is in scope.
- **J2** Blast default-rebasing WETH/USDB `[C]` → if Blast declared, B4 applies
  to WETH itself.
- **J3** = F2. **J4** bridged variants diverge `[K]` → config/README note.

## Mock recipes (gaps in d-xo)

Ship recipes, not vendored .sol — target compiler versions vary. Each mock:
minimal, one axis, explicit test controls (`setFee`, `setPaused`, `setBlocked`,
`rebase(int256)`, `setCallback`, `setReturnMode`), no realistic admin
complexity. Required recipes:

- **Rebasing** (B3–B6): share-based `balanceOf = shares * idx / 1e18`;
  `rebase(int256 delta)` moves the index both directions; transfer-full-balance
  leaves dust like stETH.
- **False-on-success** (A3): named bool return, never assigned, state changes commit.
- **Max-sentinel** (B2): `amount == type(uint256).max` → moves entire balance.
- **Phantom fallback** (A6/C10): non-reverting payable fallback; every unknown
  selector (incl. permit) silently succeeds with empty returndata.
- **Double entry point** (F1): ledger contract + thin forwarder facade; both
  addresses answer balanceOf/transfer against one storage.
- **Mutable fee** (D8): `setFee(uint256 bps)` up to 100%, optional per-address
  exemption.
- **Reverting/gas-heavy balanceOf** (E4): toggle revert; loop-burn gas mode.
- **Gas-burner transfer** (A7): configurable waste loop in transfer.

## Fixture rules

1. Resolution order: existing target-repo mock → pinned d-xo fixture already in
   the dep tree → install d-xo at a pinned commit (if deps allowed) → copy the
   single fixture with upstream path+commit provenance → local recipe mock.
   Never fetch upstream HEAD during a run.
2. **Read the fixture before trusting its name.** `ReturnsFalse` may mean
   false-on-failure or false-on-success — materially different integrations.
3. Every mock gets a small conformance test (the mock does what the catalog row
   says) — a misimplemented mock greens the protocol suite for the wrong reason.
4. Exclude mock/fixture code from coverage and mutation metrics where tooling
   permits.
5. One axis per mock by default. Composed mocks only where the surface analysis
   names a real interaction (fee+rebase vs delta accounting; deposit-succeeds-
   then-blocklisted-withdraw; reentrant hook + fee; rescue via alias address).
   No Cartesian products.

## Test-shape rules

- Dedup by internal custody primitive/adapter: one focused test per distinct
  adapter or accounting policy, plus at least one end-to-end public route per
  materially different custody path. Not every behavior × every entry point.
- Stateful/temporal behaviors (rebase-between-ops, pause-after-deposit, fee
  mutation, upgrade) are `S` suites kept SEPARATE from the strict nominal
  invariant suite — never weaken the nominal suite to accommodate them.
- Boundary values (decimals 0/2/6/8/18/24; amounts 0, 1, uint96.max, +1,
  uint256.max) are `T` table rows.
- "Unsupported" ≠ untested: if the public API accepts arbitrary token
  addresses, REJECT-SAFE containment tests are mandatory for the reachable
  families. "The call reverted" is not the assertion — assert all relevant
  state and balance deltas after the failure.

## Matrix lifecycle

Draft the matrix in scratch space during test design; the schema includes an
`implemented test(s)` column left empty at design time. After the `U`, `S`, and
`T` suites land, persist the completed matrix (`.sc-audit/weird-tokens.md` in
an audit, `test/WEIRD-TOKENS.md` in test hardening), with policy answers and
trust assumptions summarized beside it (the audit report's trust-assumptions
section, or `test/README.md`). It is a living artifact: name its owner in the
handoff.

## Closeout gate

Every TEST row — and every SUPPORTED_BY_TRUST_ASSUMPTION row's containment
smoke test — cites a named, existing test (grep-verified). Every non-TEST row
retains its evidence/user decision. Re-check a sample of exclusions against the
final tree — new tests and fixes can create new token surfaces.
