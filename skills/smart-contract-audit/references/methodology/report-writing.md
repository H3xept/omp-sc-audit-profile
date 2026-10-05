# Report writing

How to write one finding and the report around it. The template in `skill://smart-contract-audit` (section 5, Report) is authoritative; this file explains each field and states when it is done. A finding is done when a reader can do three things from the write-up alone: rerun the proof, recompute the severity, and apply the fix without guessing.

One finding is one root cause. Cluster before writing, per the rating procedure in `skill://smart-contract-audit/references/methodology/severity.md`: two symptoms that one fix removes are one finding with two locations; one symptom that needs two different fixes is two findings.

## Writing one finding

### Step 1 — Title

Name the root cause, then the impact: "`<function>` <does what wrong>, letting <actor> <gain or harm>". The title is a sentence a developer can act on without opening the body. The `ref:` suffix cites the checklist id, playbook bug class, or catalog id the finding came from; use "outside checklist" when none applies.

**Done when** the title names a function or variable, the mistake, and who gains or loses what.

### Step 2 — Location

Give `File.sol:line` (or `:start-end`) of the root cause, not of the symptom. For a missing check, point at the line where the check belongs. For a finding with several locations, list each one and say which one the fix changes.

**Done when** every location opens on a line the recommendation touches or the attack path names.

### Step 3 — Status

Write **proven** only when one of the proofs in the Evidence bar of `AGENTS.md` exists: a Foundry test that fails on the current code in the way the finding claims, a fuzzer sequence that violates a property, a Halmos counterexample, or a measured gas delta. Give the test path and the exact command. The PoC shape and its pass/fail semantics are in `skill://test-foundry/references/exploit-poc.md`. Everything else is **candidate**, however strong the reasoning.

**Done when** the status matches the evidence on disk, and the proof demonstrates every consequence the Impact line claims.

### Step 4 — Impact

State three things: the asset, the amount, and the direction (from whom to whom). Take the numbers from the PoC output. Write the amount as an absolute value at the PoC's state and as a fraction of the exposed balance. A consequence the PoC does not reach is marked `[INFERENCE]` and stays out of the rating.

**Done when** the line names the asset, a number, a source account, and a destination account (or "burned", "frozen in `<contract>`").

### Step 5 — Preconditions and the rating line

List every condition the attack needs. Classify each with the precondition table in `severity.md`: attacker-controlled, realistic state, unlikely, or out of model. The least likely one sets the likelihood. End with one rating line that a reader can recompute: "Impact Total (theft of principal). Likelihood Medium (precondition 2: vault is empty at launch). Matrix: HIGH." Name every adjustment and the rule behind it.

**Done when** every attack-path step is covered by a precondition or by "attacker-controlled", and the rating line cites the precondition that set the likelihood.

### Step 6 — Attack path

Write numbered steps. Each step is one transaction or one call, and names the caller, the function, the argument values, and the state after it. Use the PoC's values. Mark which steps share a transaction. Ordering claims ("before the victim's deposit lands") name the mechanism that gives the order: same transaction, a bundle, mempool front-running on a chain that has a public mempool.

**Done when** a reader can replay the steps by hand and reach the impact number.

### Step 7 — Proof of Concept

Inline the test function that runs the attack, the assertion that proves the impact, the run command, and the observed result lines (balances before and after, the failing assertion). Leave fixtures, deployment, mocks, and long attacker contracts in the test file and cite the path; inline only the attacker callback that does the reentry or manipulation. Copy inlined code from the file; never paraphrase it. Fork tests pin the block number and name the RPC environment variable, never a key. A candidate carries the numbered sequence from Step 6 with concrete values in place of a test.

**Done when** the inlined code equals the file's code, and the command reproduces the quoted output.

### Step 8 — Recommendation

Give a minimal before/after snippet at the root-cause location. State every behavior change the fix introduces for honest callers, integrators, and events. When several fixes exist, recommend one and give the reason. State the regression check: the original PoC passes on the fixed code and still fails on the old code, per the fix-review section of `skill://smart-contract-audit` and the diff-review mode in `skill://smart-contract-audit/references/methodology/threat-model.md`.

**Done when** the snippet compiles in context, and the text lists the behavior changes or states "none for honest callers".

## Phrasing a candidate

A candidate states what you observed, what you inferred, and what proof is missing. Keep the severity the mechanism earns; the status carries the doubt. Do not soften the title with "may" or "potentially".

- Before: "Possible reentrancy in `claim` — could potentially lead to loss of funds."
- After: "**Status:** candidate. Observed: `claim` (`Rewards.sol:88`) calls `rewardToken.transfer` at :92 before it writes `claimed[user]` at :95, and no `nonReentrant` guards it. Inferred `[INFERENCE]`: a reward token with a transfer hook (catalog E1) reenters `claim` and pays twice. Missing: no PoC — the deployment list names the reward token only as an address set by governance. Confirms: a hooked token in the supported list. Refutes: a fixed hook-free reward token."

## Report-level sections

**Executive summary.** Write it as the first paragraph under `## Scope`, labelled `**Summary.**`, for a reader who does not read code. Use four to six sentences: what was reviewed (protocol, commit, number of files); the headline result in terms of users and money; counts by severity, with proven and candidate apart; the one fix that matters most; the trust assumptions the reader accepts; and the limits of the review. Avoid jargon; when a term is needed, define it in the same sentence. Example: "We reviewed the Vault contracts at commit `a1b2c3d` (4 files). One issue lets the first depositor after launch lose their whole deposit to an attacker; a test proves it. We found 1 high, 2 medium (1 proven, 1 unproven), and 3 low issues. Seeding the vault with a small deposit at deployment closes the high issue. The owner can change fees and pause withdrawals at will; users trust the owner. This review covers the listed files only and does not certify the code as free of bugs."

**Method.** The header's `Method:` line names every reference file loaded and every tool run with its version (slither, aderyn, forge, a fuzzer). A reader can tell from it which checks never ran.

**Coverage.** Name what you walked and how far: each playbook, each checklist file with items reviewed and not applicable, the token matrix path, and the static-analysis triage counts by verdict and dismissal reason from `skill://smart-contract-audit/references/methodology/static-analysis-triage.md`. Name every in-scope file or checklist you did not finish. "No issues found" applies only to what this section lists.

**Informational and gas.** One row per item. A gas row carries the measured delta and the test that measured it; an estimate is a candidate.

**Acknowledged non-issues.** List items a reader would expect to be findings, each with the reason it is not one and the file:line that clears it. Examples: a slither `reentrancy-eth` hit on a function guarded by `nonReentrant` at `Vault.sol:41`; a first-depositor attack mitigated by `_decimalsOffset()`; an admin power cleared under the privilege rule; a token behavior the scope excludes. The section exists for three reasons. It shows the item was checked, not missed. It stops the next reviewer from re-raising it. It lets the developer reject the reasoning when the clearing assumption is wrong.

**Open questions for the developer.** List each ambiguity that changes a verdict. Phrase each as a question with the consequence of each answer: "Is `rewardToken` ever a token with transfer hooks? If yes, the `claim` candidate becomes HIGH; if no, it moves to Acknowledged non-issues." Where code and documentation disagree, the code wins: state what the code does, then ask which one is intended.

## Common write-up failures

**Vague title.**
- Before: "Reentrancy issue in Vault."
- After: "`withdraw` sends ETH before it zeroes `balanceOf`, letting a contract caller drain every depositor's ETH."

**Impact not quantified.**
- Before: "Users may lose funds."
- After: "The victim deposits 1,000 USDC and receives 0 shares. The attacker redeems 1 share for 2,000 USDC: their 1,000 USDC donation plus the victim's 1,000 USDC. Direction: victim → attacker. Attacker cost: 1 wei plus gas; the donation is recovered."

**"Front-runnable" as the whole finding.** A transaction that can be front-run is not a finding until you name what the front-runner gains.
- Before: "`initialize` can be front-run."
- After: "`initialize()` (`Vault.sol:40`) has no access control. `Deploy.s.sol:22` deploys the proxy and calls `initialize` in two separate transactions. An attacker who calls `initialize(attacker)` between them becomes owner. The deployer sees the takeover and redeploys before any deposit; no funds are at risk. Rating: LOW, per the uninitialized-proxy line in `severity.md`."

**Severity asserted, not derived.**
- Before: "Severity: High — this is very dangerous."
- After: "Impact Total: theft of depositor principal (PoC: 99.9 of 100 ETH). Likelihood Medium: the vault must be empty, a state every deployment reaches at launch. Matrix: HIGH."

**Recommendation that changes behavior silently.**
- Before: "Use `transfer()` instead of `call` to prevent reentrancy." This caps the recipient at 2300 gas and makes `withdraw` revert for most smart-contract wallets (SOL-Basics-Payment-6). The write-up does not say so.
- After:

```solidity
// before
(bool ok,) = msg.sender.call{value: balanceOf[msg.sender]}("");
require(ok);
balanceOf[msg.sender] = 0;

// after
uint256 amount = balanceOf[msg.sender];
balanceOf[msg.sender] = 0;
(bool ok,) = msg.sender.call{value: amount}("");
require(ok);
```

"Behavior change: none for honest callers; `withdraw` still forwards all gas. Add `nonReentrant` when another function reads `balanceOf` during the call."

**Claim larger than the proof.**
- Before: "An attacker can drain the whole protocol."
- After: "The PoC drains the USDC pool (1.2M USDC). The WETH pool uses the same `_price` path `[INFERENCE]`; no PoC covers it."
