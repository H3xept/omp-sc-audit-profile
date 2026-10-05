# Governance playbook

Load when: the code has `propose`/`castVote*`/`queue`/`execute`, a Governor (OZ `Governor*`, Compound Alpha/Bravo, custom DAO), a timelock (`TimelockController`, Compound `Timelock`), vote checkpoints (`ERC20Votes`, `ERC721Votes`, `getPastVotes`, `delegate`), vote-escrow locks (`VotingEscrow`, veNFT), gauge/voter contracts or bribe markets, or any guardian/emergency path that acts on treasury or protocol parameters.

## Core invariants

1. Frozen weight: once a proposal's snapshot timepoint has passed, no action changes any account's voting weight for that proposal.
2. No double counting: the sum of weight cast on a proposal is at most the total voting supply at its snapshot.
3. One vote per account per proposal, counted once.
4. Delegation conservation: the sum of `getVotes(d)` over all delegatees equals the supply held by accounts that have a delegatee, at every timepoint.
5. History immutability: `getPastVotes(a, t)` and `getPastTotalSupply(t)` return the same value for every query made after `t`.
6. Quorum for a proposal is a function of state at its snapshot only.
7. Every privileged call on treasury or protocol parameters passes propose → vote → queue → delay ≥ `minDelay` → execute; no other address holds the roles or ownership the timelock holds.
8. Executed code and calldata are byte-identical to what was voted on.
9. A proposal executes at most once; canceled, defeated and expired proposals never execute, in the Governor and in the timelock.
10. ve decay: a lock's power is `amount × (end − now) / MAXTIME`, non-increasing over time absent deposits or extensions, zero at `end`.
11. ve aggregation: the sum of every lock's power at `t` equals the global power at `t`, within a rounding bound proportional to the number of locks.
12. Gauge weight: per epoch, the weight a position allocates across gauges is at most its power, and that power is counted once even after transfer, merge or split.

## Where value moves

- Entry points: `propose`, `castVote`/`castVoteBySig`/`castVoteWithReasonAndParams`, `delegate`/`delegateBySig`, every token path that moves balance (`_update`, `_afterTokenTransfer`, `_mint`, `_burn` overrides), lock `create`/`increaseAmount`/`increaseUnlockTime`/`withdraw`/`merge`/`split`/`depositFor`, gauge `vote`/`reset`/`poke`, bribe `notifyRewardAmount`/`getReward`.
- Exit points: `execute`, `relay`, timelock `execute`/`executeBatch`, treasury transfers, token mint via governance, emergency functions (guardian cancel/veto, pause, fast-track commit), bribe and emission claims.
- Privileged parameters: `votingDelay`, `votingPeriod`, `proposalThreshold`, quorum numerator, `minDelay`, timelock `PROPOSER_ROLE`/`EXECUTOR_ROLE`/`CANCELLER_ROLE`/`DEFAULT_ADMIN_ROLE`, Governor `updateTimelock`, guardian addresses, ve smart-wallet allowlist, gauge whitelist/kill.
- External dependencies: the votes token and its clock, lending/flash-loan liquidity of the governance token and of any asset counted as voting power, bribe markets, off-chain vote executors (Safe modules, Snapshot bridges).
- Ownership map: for every contract the DAO controls, record the address that owns each protected function. Each owner that is not the timelock is a bypass to justify.

## Bug classes

### Flash-loan and same-block voting power
- Mechanism: weight read at vote time instead of at a past snapshot. Beanstalk's governance counted Stalk at the moment of voting and offered `emergencyCommit` for a 2/3 supermajority after one day; the attacker flash-borrowed liquidity, deposited it into Beanstalk-whitelisted Curve LP for Stalk, voted for BIP-18 and executed it in one transaction, draining about $182M.
- Where: `balanceOf`/`getVotes` (current) inside vote counting; `getPastVotes(account, block.number)` in custom checkpoint code that allows the current timepoint; weight derived from LP or vault shares whose supply is flash-mintable (SOL-Token-FE-9); `votingDelay = 0`, where power bought after the proposal transaction in the same block or timestamp counts.
- Question: can weight be acquired after the proposal becomes visible and still count, and can it be returned before anything forces the holder to keep it?
- Prove: one-transaction PoC: flash loan → acquire weight → `propose`/`castVote` → `execute`; assert it reverts. Property: weight used for proposal P equals `getPastVotes(voter, snapshot(P))`.

### Clock and snapshot timing
- Mechanism: Governor and token disagree on the clock (ERC-6372 `clock()`/`CLOCK_MODE()`): a block-number Governor querying a timestamp-checkpointed token reads near-genesis history and every vote weighs zero, or the reverse. `votingDelay`/`votingPeriod` written in blocks while the clock is timestamps. On L2s, `block.number` and block cadence differ from L1 (SOL-McCc-1, SOL-McCc-11); several blocks can share one timestamp, so a timestamp snapshot equal to the proposal's timestamp includes later same-second blocks.
- Where: custom `clock()`, `_getVotes`, `proposalSnapshot`, token upgrades that switch clock mode while checkpoints exist.
- Question: are the Governor's timepoints, the token's checkpoint keys and every delay parameter in one unit, and can the clock mode change after checkpoints were written?
- Prove: deploy Governor and token with mismatched clocks; vote with a delegated holder; assert nonzero weight.

### Delegation and checkpoint accounting
- Mechanism: votes move between the wrong accounts. SushiToken's `_beforeTokenTransfer` called `_moveDelegates(from, to, amount)` instead of `_moveDelegates(_delegates[from], _delegates[to], amount)`, so transfers subtracted from accounts with no checkpoint (revert) or left weight with the old delegatee (double voting). Redelegation that moves `balanceOf(delegator)` from the old delegatee breaks when the balance changed without a matching vote move (rebasing, fee-on-transfer, a mint path that skips the hook).
- Where: `_delegate`, `_moveDelegates`/`_moveVotingPower`, `_writeCheckpoint` (two writes in one timepoint must overwrite, not push), binary search boundaries in `getPastVotes` (SOL-Heuristics-7), `delegateBySig` nonce/expiry/domain (SOL-Signature-1, SOL-Signature-5), self-transfer and self-delegation (SOL-Heuristics-3), mint/burn overrides that bypass the votes hook.
- Question: after any sequence of transfer, mint, burn, delegate and redelegate, does every delegatee's weight equal the sum of its delegators' balances?
- Prove: stateful fuzz with actors transferring and redelegating; properties: invariant 4, and `getPastVotes` unchanged for past timepoints after each call.

### Double voting by moving weight
- Mechanism: per-account `hasVoted` combined with weight read from a balance or NFT that can move: vote, transfer to a fresh account, vote again. veNFT variants: vote, then merge/split/transfer into a new tokenId that has not voted this epoch.
- Where: vote functions without a snapshot, `merge`/`split`/`transferFrom` on veNFTs without a `voted[tokenId]` or epoch check, ERC721 governance that weighs by `balanceOf(owner)` while recording votes per tokenId.
- Question: after a vote, what operations on the weight-bearing asset are still allowed in the same proposal or epoch?
- Prove: vote → transfer/merge/split → vote again; assert the second vote reverts or carries zero weight. Property: invariant 2.

### Proposal creation, threshold and frontrunning
- Mechanism: OZ `hashProposal` is `keccak256(abi.encode(targets, values, calldatas, descriptionHash))`, independent of the proposer. Anyone can frontrun `propose` with identical arguments, become `proposalProposer`, and cancel while `Pending` (OZ lets the proposer cancel in that state), so the victim's id is burned. Current OZ Governor honors a `#proposer=0x…` description suffix that restricts who may submit; forks and older versions may lack it. Compound Bravo `cancel` lets any caller cancel a non-whitelisted proposal once `getPriorVotes(proposer, block.number - 1) < proposalThreshold`, so the proposer's delegators can cancel by undelegating or moving tokens.
- Where: `propose`, `cancel`, threshold reads (`getVotes(proposer, clock() - 1)`), threshold expressed as a share of a supply governance can mint, threshold 0 (spam and storage-growth DoS on proposal arrays, SOL-Basics-AL-9).
- Question: who can create, own and cancel a proposal with the same id, and can the threshold be met or broken by someone other than the proposer?
- Prove: frontrun-then-cancel test; assert the honest proposer can still create the proposal.

### Quorum computed on the wrong supply
- Mechanism: quorum from current `totalSupply()` instead of `getPastTotalSupply(snapshot)`, so minting or burning after the snapshot moves the bar; quorum numerator updates applied retroactively to live proposals (OZ `GovernorVotesQuorumFraction` before 4.7.2, SOL-Basics-VI-OVI-11); supply counting undelegated or treasury-held tokens makes quorum unreachable; quorum counting rules (OZ `GovernorCountingSimple` counts For + Abstain) not matching the spec.
- Where: `quorum(timepoint)`, `_quorumReached`, `updateQuorumNumerator`, supply getters of ve tokens at past timestamps.
- Question: is every input to quorum read at the snapshot, and can circulating-but-undelegated supply block quorum forever?
- Prove: create proposal, mint or burn, then check `quorum(snapshot)` is unchanged and outcome is unchanged.

### Timelock bypass
- Mechanism: a path reaches protected functions without the delay. `PROPOSER_ROLE` held by an EOA or multisig beside the Governor; `DEFAULT_ADMIN_ROLE` kept by an optional constructor `admin` (OZ `TimelockController` grants it to `address(this)` and to that argument) who grants itself roles instead of renouncing; `minDelay = 0` at construction; protected contracts owned by a multisig or by the Governor instead of the timelock; fast-track paths (Beanstalk `emergencyCommit`, guardian execute).
- Where: timelock constructor arguments and `RoleGranted` history, `owner()`/`hasRole` on every DAO-controlled contract, `updateDelay` (only callable by the timelock itself), emergency functions.
- Question: for each protected function, list every caller that can reach it and the minimum time between intent becoming public and execution.
- Prove: read live roles and owners with `skill://onchain-forensics`; for a code path, a test that executes a privileged call with zero delay. Rate severity with `skill://smart-contract-audit/references/methodology/severity.md` (centralization findings are preconditioned on the role holder).

### Malicious or mutable proposal payloads
- Mechanism: the code executed differs from the code reviewed. Tornado Cash (2023) executed proposals by `delegatecall` into a proposal contract. The attacker's proposal looked like an earlier approved one but carried a `selfdestruct` path. After it passed, the attacker destroyed the proposal and its CREATE2-deployed deployer, redeployed the deployer at the same address (nonce reset to zero), then CREATE-deployed different code at the original proposal address. That code wrote `lockedBalance` slots giving 100 attacker accounts 10,000 TORN each, which were then unlocked and drained.
- Where: governors that `delegatecall` a proposal target, targets that are proxies upgradable by someone other than the DAO, Bravo `signature` + `data` pairs (empty signature means `data` carries its own selector), `value` fields, approvals and `upgradeTo`/`grantRole` buried in batches. EIP-6780 (Cancun) limits SELFDESTRUCT code deletion to the creation transaction on chains that adopted it; check the deployment chains (`skill://smart-contract-audit/references/chain-specific.md`).
- Question: does execution bind to the reviewed code (stored `extcodehash` checked at execute) and to the reviewed calldata, and can any target's code or implementation change between vote and execution?
- Prove: metamorphic redeploy test on a chain config without EIP-6780, or a proxy upgrade between `queue` and `execute`; assert `execute` reverts.

### Operation id collisions
- Mechanism: `TimelockController` ids are `keccak256(abi.encode(targets, values, payloads, predecessor, salt))`. Two governors sharing one timelock with the same description collided until OZ made the salt `bytes20(address(this)) ^ descriptionHash`; custom governors using `salt = descriptionHash` or `0` cannot queue a repeated proposal (recurring payment) while the old id exists, and cancelling one cancels the shared operation. Compound Bravo keys queued actions by `(target, value, signature, data, eta)`: a proposal with two identical actions, or two proposals with an identical action queued in the same block, revert with "identical proposal action already queued at eta".
- Where: `_queueOperations`, `_timelockSalt`, Bravo `queueOrRevertInternal`, any shared timelock.
- Question: can two legitimate proposals produce the same operation id, and what happens to the second?
- Prove: queue two proposals with identical actions from one and from two governors.

### Cancel and veto rights
- Mechanism: Governor cancel that does not cancel the timelock operation (with an open `EXECUTOR_ROLE`, anyone then executes it directly on the timelock); `CANCELLER_ROLE` or a guardian with unbounded veto; cancel allowed in states where it should not be (after queue, by non-proposers).
- Where: `cancel`/`_cancel`, `GovernorTimelockControl._cancel`, Bravo `cancel` condition, guardian functions.
- Question: after a cancel in the Governor, is there any address that can still execute the operation?
- Prove: cancel through the Governor, then call timelock `execute` from an unprivileged account.

### Vote-escrow lock math
- Mechanism: Curve-style `slope = amount / MAXTIME`, `bias = slope × (end − now)`, `end` rounded down to `WEEK`. Truncation makes per-lock slopes and biases sum differently from the global point; forks that subtract a user's slope or bias from the global value with checked arithmetic (or without clamping at zero) revert every later checkpoint once rounding drift exceeds the global value. Other breaks: `increaseUnlockTime` beyond `MAXTIME`, deposits into expired locks, `depositFor` extending or griefing someone else's lock (SOL-Defi-Staking-1), early-unlock penalties rounding to zero on small amounts, permanent-lock flags skipping decay, `balanceOfAt(block)` interpolation between points, delegation of ve power without checkpoint parity.
- Smart-contract lockers: Curve gates `create_lock`/`increase_*` with `assert_not_contract`, allowing a contract only if `SmartWalletChecker.check` returns true; checks based on `msg.sender != tx.origin` change meaning under EIP-7702 (`skill://smart-contract-audit/references/account-abstraction.md`).
- Where: `_checkpoint`, `supply_at`/`totalSupplyAt`, `balanceOfNFTAt`, `merge`, `split`, `withdraw`, penalty math (SOL-Basics-Math-2, SOL-Basics-Math-5, SOL-Heuristics-10).
- Prove: fuzz sequences of create/increase/extend/withdraw/merge across week boundaries; properties: invariant 10, invariant 11 within n wei, no revert in `_checkpoint` reachable by a user action.

### Gauge and bribe manipulation
- Mechanism: weight or eligibility read at claim time instead of epoch snapshot. Velodrome (Code4rena 2022-05, H-05): voting overwrote `checkpoint.voted` in the last checkpoint, so a user could vote right before claiming and collect full-period rewards. Others: `poke` refreshing weight without a vote, killed gauges keeping weight in `totalWeight`, bribe tokens that revert in reward loops blocking claims (SOL-AM-DOSA-6), voting power used on gauges and then moved to a fresh veNFT, emissions directed to an attacker-controlled gauge.
- Where: `Voter.vote`/`reset`/`poke`, `Bribe._writeCheckpoint`, `getReward`, `distribute`, epoch boundary checks (SOL-AM-MA-1).
- Question: for each reward stream, at which timepoint is the voter's eligibility measured, and can the same power earn twice in one epoch?
- Prove: vote in the last block of an epoch with a fresh lock, claim, reset, revote; assert rewards are pro-rata to time-weighted eligibility.

### Emergency powers and hostile takeover
- Mechanism: short paths and cheap control. Build Finance (2022): with little attention on the proposal, an actor holding enough BUILD passed a proposal handing itself the token contract, minting keys, governance contract and treasury, then minted and sold BUILD. Audius (2022): a storage collision between the proxy's `proxyAdmin` slot and `Initializable` flags allowed re-initializing the governance contracts, after which the attacker passed and executed a treasury-draining proposal (SOL-Basics-PU-9, `skill://smart-contract-audit/references/upgradeability.md`).
- Where: fast-track functions, guardian powers, governance-callable `mint`, initialization of upgradeable governance, quorum relative to circulating supply.
- Question: what does it cost (tokens to buy or borrow at current liquidity) to reach quorum and majority, compared with the value governance can move in one proposal?
- Prove: economic table plus a fork test acquiring quorum on the live pool depth; for code paths, an initializer re-entry test.

## Checklist items to walk

- Timelock and admin: SOL-Timelock-1, SOL-CR-1, SOL-CR-2, SOL-CR-3, SOL-CR-4, SOL-CR-5, SOL-CR-6, SOL-CR-7, SOL-Basics-AC-1, SOL-Basics-AC-2, SOL-Basics-AC-4, SOL-Basics-AC-5, SOL-AM-RP-1
- OZ governance advisories: SOL-Basics-VI-OVI-2, SOL-Basics-VI-OVI-6, SOL-Basics-VI-OVI-11, SOL-Basics-VI-OVI-14, SOL-Basics-VI-OVI-18
- Flash loans and voting power: SOL-Defi-FlashLoan-1, SOL-Token-FE-9, SOL-AM-SybilAttack-1, SOL-AM-PMA-1
- Timing and ordering: SOL-AM-MA-1, SOL-AM-MA-3, SOL-Basics-Function-3, SOL-AM-FrA-1, SOL-McCc-1, SOL-McCc-11
- Signatures: SOL-Signature-1, SOL-Signature-2, SOL-Signature-5, SOL-AM-ReplayAttack-2
- Payload execution: SOL-EC-3, SOL-EC-10, SOL-EC-11, SOL-Basics-PU-6, SOL-Basics-VI-EAI-1, SOL-Integrations-GS-1, SOL-Integrations-GS-2
- Upgradeable governance: SOL-Basics-PU-2, SOL-Basics-PU-5, SOL-Basics-PU-9, SOL-Basics-PU-10, SOL-Basics-Initialization-2
- Math and accounting: SOL-Basics-Math-2, SOL-Basics-Math-5, SOL-Heuristics-3, SOL-Heuristics-7, SOL-Heuristics-10, SOL-Heuristics-12, SOL-Heuristics-17, SOL-Defi-Staking-1, SOL-Defi-Staking-2, SOL-Defi-Staking-3
- Loops and DoS: SOL-Basics-AL-9, SOL-Basics-AL-10, SOL-AM-DOSA-6
- Whole categories: `skill://smart-contract-audit/references/upgradeability.md`, `skill://smart-contract-audit/references/arbitrary-calls-approvals.md`, `skill://smart-contract-audit/references/chain-specific.md`, `skill://smart-contract-audit/references/account-abstraction.md`

PoC shapes: `skill://test-foundry/references/exploit-poc.md`. Delegation, quorum and ve properties: `skill://fuzz-echidna-medusa/references/property-catalog.md`. Prior incidents in depth: `skill://smart-contract-audit/references/methodology/exploit-casebook.md`.

## Precedent

- SushiToken (Code4rena 2021-09 Sushi MISO): `_moveDelegates(from, to, …)` used holders instead of their delegatees. https://github.com/code-423n4/2021-09-sushimiso-findings/issues/117
- Build Finance DAO, 2022: proposal passed by a large holder handed over the token contract, minting keys and treasury. https://decrypt.co/92970/build-finance-dao-falls-to-governance-takeover
- Beanstalk, 2022: flash-loaned Stalk voted and executed BIP-18 through `emergencyCommit` in one transaction; about $182M drained. https://immunefi.com/blog/bug-fix-reviews/hack-analysis-beanstalk-governance-attack-april-2022/
- Velodrome (Code4rena 2022-05, H-05): voting overwrote the last checkpoint's `voted` flag, enabling vote-just-before-claim reward capture. https://github.com/code-423n4/2022-05-velodrome-findings/issues/206
- Audius, 2022: proxy/`Initializable` storage collision allowed re-initializing governance, then a self-passed proposal moved about 18M AUDIO. https://blog.audius.co/posts/audius-governance-takeover-post-mortem-7-23-22
- Tornado Cash, 2023: CREATE2 + CREATE + SELFDESTRUCT replaced an approved proposal's code before its `delegatecall` execution. https://www.coinspect.com/learn-evm-attacks/cases/tornadocash-governance-takeover/ (PoC: https://github.com/pcaversaccio/tornado-cash-exploit)
- OpenZeppelin PR 4432, 2023: governor address added to the timelock salt after a Certora finding that two governors sharing a timelock could block each other. https://github.com/OpenZeppelin/openzeppelin-contracts/pull/4432
