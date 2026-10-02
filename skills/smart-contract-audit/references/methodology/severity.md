# Severity

The single source of truth for severity in this profile. Every finding, in every skill and pipeline phase, is rated with this file. The output labels are the pipeline's closed set: `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, `INFORMATIONAL`, and `GAS`.

Severity and proof are separate axes. Severity answers "how bad, if the mechanism holds"; status and confidence answer "is it proven". A finding without proof keeps the severity its mechanism earns and stays a **candidate** until a proof lands (see the Evidence bar in `AGENTS.md`).

## Rating procedure

Run these steps for each finding after clustering, so one root cause gets one rating.

1. **Impact.** Pick the impact level from the table below for the worst consequence the proof demonstrates. A consequence the PoC does not reach is `[INFERENCE]` and stays out of the rating. Done when you can name the impact level and the asset and amount (or fraction) that moves.
2. **Preconditions.** List every condition that must hold for the attack path to run, and classify each one with the precondition table. Done when every step of the attack path is covered by a listed condition or by "attacker-controlled".
3. **Likelihood.** Take the least likely precondition class as the likelihood. Done when the likelihood level cites the precondition that set it.
4. **Matrix.** Read the severity off the matrix.
5. **Adjust.** Apply the privilege rule, then the misrating list. Each adjustment names its rule. Done when every move away from the matrix cell has a stated reason.
6. **Write it down.** The write-up states impact level, likelihood level, the preconditions, and any adjustment. A reader can recompute the rating from the write-up alone.

## Impact levels

| Level | Consequence |
|---|---|
| **Total** | Direct theft of user or protocol principal, at rest or in motion. Permanent freeze of funds or NFTs. Protocol insolvency: liabilities (shares, debt, redeemable claims) exceed assets. Unauthorized mint of a value-bearing asset. An unprivileged party gains an admin, upgrade, or minter role. A governance outcome differs from the vote. |
| **Major** | Theft or permanent freeze of yield, rewards, or fees that have accrued and are claimable. Temporary freeze of principal that lasts more than a week, or that blocks a time-sensitive action (liquidation, withdrawal before a deadline, auction settlement, vote) so that a loss follows. A loss of principal that is real but bounded to a fraction of a position. |
| **Moderate** | Loss of yield not yet accrued, or fees the protocol should have charged. Griefing: the attacker pays (gas, capital at risk, forfeited value) and gains nothing, while users or the protocol lose value or availability. Temporary denial of service of a core function shorter than a week. Value leak through ordering (sandwich, back-run) bounded by a user's own slippage setting. Core functionality broken with no fund loss. |
| **Minor** | Broken non-core functionality. A view function returns a wrong value that no state-changing path consumes. Rounding loss below the material threshold below. Spec or EIP deviation with no integration that depends on it. Events with wrong values that nothing on-chain consumes. |
| **None** | No security consequence: style, naming, documentation, dead code, missing events for monitoring. Rated `INFORMATIONAL`. |

**Material threshold.** A loss is material when it exceeds both 0.01% of the affected position or pool and $10 at realistic prices (the Sherlock "relevant loss" bar, used here because it is concrete). A per-call loss below the bar that an attacker can repeat in a loop, or amplify (low-decimal tokens, many small positions, a flash-loaned position), is rated on the total it reaches — the PoC must show the repetition or amplification.

## Likelihood levels and preconditions

| Precondition class | Examples | Likelihood it sets |
|---|---|---|
| **Attacker-controlled** | Deploying a contract, choosing inputs, flash-borrowing capital, calling permissionless functions, waiting for a public event, ordering own transactions, front-running on a chain with a public mempool | **High** |
| **Realistic state** | A state normal operation reaches: empty vault at launch, a token from the supported list with its documented behavior, oracle price moving inside its deviation band, a victim making a routine call, a keeper running late within its normal window, attacker capital at risk but recoverable | **Medium** |
| **Unlikely** | An honest admin setting a value inside the documented valid range that happens to break something; extreme but historical market moves (sharp depegs, oracle outages); a trusted external protocol behaving inside its spec in a rare way; several realistic states that must coincide in one block; attacker cost far above the gain | **Low** |
| **Out of model** | Leaked keys; a malicious or reckless trusted role; a user hurting only themselves by bad input; tokens the scope excludes; reorgs deeper than the chain's finality; future code | Not a security finding. Record as `INFORMATIONAL` or under "Acknowledged non-issues", with the reason. |

Likelihood is the **least likely** precondition, never an average. Two independent Medium preconditions that must hold at the same moment are Low unless you show they co-occur routinely.

Economic feasibility moves likelihood, not impact. Compute attacker cost (gas, fees, capital lost to slippage or the attack itself) against gain. Cost above gain turns a theft into griefing (Moderate impact) unless a third party pays the cost.

## Matrix

| Impact \ Likelihood | High | Medium | Low |
|---|---|---|---|
| **Total** | CRITICAL | HIGH | MEDIUM |
| **Major** | HIGH | MEDIUM | LOW |
| **Moderate** | MEDIUM | MEDIUM | LOW |
| **Minor** | LOW | LOW | LOW |
| **None** | INFORMATIONAL | INFORMATIONAL | INFORMATIONAL |

`GAS` sits outside the matrix. A gas item carries a measured `vm.snapshotGasLastCall` (or equivalent) delta between the current code and the change; an estimate is a candidate. Gas items are reported apart from security findings.

## Privilege rule

Trusted roles — owner, admin, governance, guardians, any role the documentation names as trusted — act in good faith and preview their calls. This matches the Privilege Rule in `skill://audit-pipeline/assets/prompts/da-protocol.md`.

- **"A trusted role can steal or brick funds"** by using its powers as written is a centralization note: `INFORMATIONAL`, listed so the reader knows the trust assumption. It is not a vulnerability.
- **A stated restriction the code fails to enforce** is an access-control bug, rated on the normal matrix. Examples: the docs promise a 48-hour timelock on upgrades and one path skips it; a fee is documented as capped at 10% and the setter has no cap; a guardian can pause but the code also lets it sweep.
- **The four surviving patterns** from the DA protocol rate on the normal matrix with likelihood Medium by default, because the admin acts honestly: authority propagation (an honest parameter enables an unprivileged exploit), composition failure (an admin action in protocol A enables an exploit in B), flash-loan governance (voting power can be borrowed — this one is attacker-controlled, so High), and config interaction (two individually valid parameters combine into a vulnerability).
- **Admin mistakes outside the documented range** (fee of 200%, zero address for a core dependency) are out of model.
- **Roles anyone can obtain** — permissionless keepers, market creators, anyone who pays a fee for a role — are unprivileged actors. Rate their abuse like any user's.

## Platform mapping

Use this table to translate a rating when the user names a platform, or to sanity-check against the platform's own rules. The platform's published rules win for submissions to that platform; this profile's matrix wins everywhere else.

| This profile | Code4rena | Sherlock | Immunefi (v2.3, smart contracts) |
|---|---|---|---|
| CRITICAL | High (3) | High | Critical |
| HIGH | High (3) when the attack path has no hand-wavy hypotheticals; otherwise Medium (2) | High when the loss exceeds 1% and $10 without extensive external conditions; otherwise Medium | Critical for Total impact, High for Major impact; Immunefi may downgrade for required privileges or uncommon user interaction |
| MEDIUM | Medium (2) | Medium: loss over 0.01% and $10 under external conditions, broken core functionality, or a DoS that locks funds over a week or hits a time-sensitive function | High for temporary freeze; Medium for griefing, block stuffing, unbounded gas consumption, theft of gas, or a contract unable to operate for lack of token funds |
| LOW | QA (Low risk) | Not rewarded (Sherlock judges only High and Medium) | Low: contract fails to deliver promised returns but does not lose value; otherwise usually out of scope |
| INFORMATIONAL | QA; pure informational items are discouraged; centralization and admin-privilege items go in the QA report | Not rewarded; design decisions are informational | Out of scope by default (best-practice recommendations, centralization risks) |
| GAS | Not part of the severity scale | Invalid (gas optimizations, VII.1) | Not an impact category; "theft of gas" and "unbounded gas consumption" are security impacts, not optimizations |

Platform rules that change ratings, each verified on the platform's page:

- **Code4rena.** Dust losses (rounding errors, marginal fee variation) are QA. Loss of matured yield counts as loss of capital; loss of unmatured yield is capped at Medium. Reckless admin mistakes are invalid; misuse of privileges goes in the QA report; privileged scenarios "with reasonable assumptions" reach Medium at most. Findings that need a user to enter wrong input are QA at best. Non-standard and fee-on-transfer tokens are out of scope unless listed as supported, with USDT always in scope. Event-only impacts are capped at Low unless the event feeds an on-chain process. The approve front-running race is not a valid vulnerability.
- **Sherlock.** Likelihood is not considered when assigning severity — only the external conditions in the High/Medium definitions. Front-running issues on chains with a private mempool drop a level (High → Medium, Medium → invalid), and the report must show unintentional front-running. Sequencer downtime, chain reorgs, and network liveness issues are invalid. Recommending stale-price or round-completeness checks is invalid, except for pull oracles such as Pyth. Non-standard tokens are invalid unless the README lists them; decimals between 6 and 18 are not weird. Missing storage gaps are Low except in complex inheritance. Wrong values in view functions are Low unless a state-changing path consumes them. Breaking a README-declared invariant can be Medium even with low impact. Out-of-gas from user-filled arrays can be Medium, or High if it locks all funds forever; admin-controlled array length is Low.
- **Immunefi.** Severity is impact-led; elevated privileges or uncommon user interaction downgrade or reject. Default out-of-scope impacts include leaked keys, attacks needing privileged addresses, incorrect data from third-party oracles (oracle manipulation and flash-loan attacks stay in scope), 51% attacks, lack of liquidity, Sybil attacks, centralization risks, and depegs of external stablecoins the bug does not cause. Each program can override the defaults; read the program page.

Sources opened for this table: [Code4rena severity categorization](https://docs.code4rena.com/competitions/severity-categorization.md), [Sherlock criteria for issue validity](https://docs.sherlock.xyz/audits/judging/guidelines), [Immunefi Vulnerability Severity Classification System v2.3](https://immunefi.com/immunefi-vulnerability-severity-classification-system-v2-3/). All three revise their rules; re-open the page before rating a live submission.

## Common misratings

Each line is a rating that reviewers commonly get wrong, the rating this rubric gives, and the check that decides it.

- **"Rounding loses value."** Loss of dust is `LOW`. It becomes Major or Total only when a PoC shows the loss repeated or amplified past the material threshold — a loop that rounds in the attacker's favour each call, a low-decimal token (catalog G4 in `skill://smart-contract-audit/references/weird-erc20.md`), or a share price inflated so one wei of shares is worth a material amount.
- **"First depositor can inflate the share price"** when the vault has a mitigation. Check the actual mitigation before rating. OpenZeppelin `ERC4626` (since v4.9) adds virtual shares and assets through `_decimalsOffset()`; [its NatSpec](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol) states the default offset 0 already makes the attack non-profitable and larger offsets make it orders of magnitude costlier — unless the vault overrides `_convertToShares`/`_convertToAssets`, which restores pre-v4.9 behavior. Dead shares minted to a burn address on first deposit, a seeded deposit in the deployment script, or a minimum first deposit also mitigate; confirm the deployment script actually does it. With a working mitigation, the residual is griefing at a loss to the attacker: `LOW` or `MEDIUM` by measured victim loss. Without one, on a vault anyone can be first into: Total impact, Medium likelihood (realistic state: empty vault) → `HIGH`.
- **"Admin can rug."** `INFORMATIONAL` centralization note under the privilege rule, unless a documented restriction is bypassed.
- **"Unbounded loop → DoS."** Compute it: gas per iteration from a measured run, times the length an attacker can reach at what cost, against the block gas limit of the target chain. Attacker-growable and bricks withdrawals for everyone → Major or Total impact. Admin-controlled length, or realistic lengths far under the limit → `LOW`.
- **"Front-running" on an L2 whose sequencer keeps a private mempool.** Intentional mempool watching is out of model there; likelihood drops to Low, and Sherlock drops the severity a level. Unintentional ordering (two honest users, a keeper and a user in the same block) still applies and keeps its likelihood.
- **"No staleness check on the oracle."** Name the concrete feed, its heartbeat and deviation threshold on the target chain, and the loss a stale price within that window causes. Without that, `LOW`.
- **"Fee-on-transfer / rebasing token breaks accounting"** when the token is not in the supported list: out of model. When it is supported, rate the measured accounting gap normally. The behavior catalog and dispositions live in `skill://smart-contract-audit/references/weird-erc20.md` (B1, B4).
- **"User can lose funds by passing the wrong argument."** Out of model when only that user is hurt. If one user's input damages other users or the protocol, rate that damage.
- **"Blocklisted recipient makes the call revert."** Only the blocked user is hurt → out of model. One blocked address bricks a batch, a queue, or a liquidation for everyone → rate the shared impact (catalog D4).
- **"Uninitialized proxy / front-runnable initializer."** If the deployer can redeploy with no loss, `LOW`. If the takeover yields an admin or upgrade role over live funds, or a path that bricks the implementation every proxy delegates to, Total impact.
- **"Could drain the whole protocol"** in the impact line when the PoC drains one pool. Rate what the PoC drains; mention other reachable pools as `[INFERENCE]` in the write-up, or extend the PoC.
- **"Reentrancy"** on a function guarded by `nonReentrant` on every entry point that shares the state, or whose external call only reaches a trusted contract. Dismiss, recording the guard's file and line.
