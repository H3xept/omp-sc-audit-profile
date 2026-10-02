# Staking and rewards playbook

Load when: the code streams or distributes rewards to holders of a balance: `rewardPerToken`/`rewardPerTokenStored`/`accRewardPerShare`, `userRewardPerTokenPaid`/`rewardDebt`, `notifyRewardAmount`, `earned`/`getReward`/`claim`, MasterChef `updatePool`, gauges, vote-escrow locks (`createLock`/`increaseUnlockTime`), epoch or Merkle reward claims, or fee-sharing share tokens.

## Core invariants

1. For every account, `earned(account)` changes only by `balance(account) * (rewardPerToken_now - userRewardPerTokenPaid[account])`; any balance change of the account is preceded in the same call by a checkpoint of that account.
2. `sum(claimed) + sum(earned(all accounts)) <= sum(rewards notified)` at all times; the excess is the undistributed remainder, and it is never negative.
3. `rewardRate * (periodFinish - lastUpdateTime)` never exceeds the reward-token balance held for the stream minus rewards already earned but unclaimed.
4. `rewardPerTokenStored` is monotonically non-decreasing and is updated with `lastUpdateTime` in the same write.
5. Two accounts with the same balance over the same interval earn the same reward (±1 wei), regardless of how often either calls `getReward`, `stake`, or transfers.
6. Moving a staked balance between two accounts (transfer, delegate, merge, split) conserves the sum of their future rewards and does not reset or duplicate accrued rewards.
7. When the reward token equals the staking token, staked principal is never paid out as reward.
8. A vote-escrow balance at time `t` equals `amount * (lockEnd - t) / MAXTIME` (or the documented curve), so total voting power equals the sum of user powers at every checkpointed timestamp.

## Where value moves

- **Entry:** `stake`/`deposit`, `notifyRewardAmount`/`addReward`/`depositReward`, transfer of the receipt token (moves future rewards), `createLock`/`increaseAmount`/`increaseUnlockTime` (some allow acting on behalf of another address), merge/split of NFT locks.
- **Exit:** `withdraw`, `getReward`/`claim`/`claimFor`/`harvest`, `exit`, `emergencyWithdraw` (skips reward checkpoint by design: confirm it zeroes rewards), `recoverERC20`/`sweep`, early-unlock penalty paths.
- **Privileged parameters:** `rewardsDuration`, reward distributor role, reward token list, allocation points per pool, boost multipliers, lock max time, penalty rates, epoch roots for Merkle distributors.
- **External dependencies:** reward-token behavior (decimals, fee-on-transfer, rebasing), staking-token behavior, the source that calls `notifyRewardAmount` (keeper, gauge controller, bribe market), block timestamp.

Draw the checkpoint graph: for each function that changes any account's balance or the total supply, list which accounts it checkpoints before the change. Every missing edge is a candidate finding.

## Bug classes

### Missing or misordered checkpoint
- **Mechanism:** a path changes `balanceOf[user]` or `totalSupply` without first calling `updateReward(user)`. The user then earns at the old `userRewardPerTokenPaid` on a new balance (over-pay) or loses accrued reward (under-pay). Receipt-token transfers are the most frequently missed path: Popsicle's LP share transfers did not checkpoint sender and receiver, so the same shares collected fees repeatedly.
- **Where to look:** `_transfer`/`_update` overrides of the receipt token, `mint`/`burn` hooks, liquidations or slashing that reduce stake, batch/migrate functions, `emergencyWithdraw`, delegation changes, boost recalculation.
- **Ask:** for every write to a balance or the total, is the accumulator updated first, and are both counterparties checkpointed?
- **Prove:** PoC: stake on A, wait, transfer shares to B, claim from A and B; assert total claimed exceeds the accrued reward. Property: invariant 5 across random transfer and claim sequences.

### Stale cached accumulator
- **Mechanism:** the function copies pool state into `memory`, updates storage through a different path, then writes or reads the stale copy. Cover Protocol's Blacksmith computed `rewardWriteoff` from a cached `accRewardsPerToken` that the pool update had already changed, and the tiny pool supply amplified it into an unbounded mint.
- **Where to look:** `Pool memory pool = pools[id]` followed by `_updatePool(id)` and later reads of `pool`; struct copies in loops; local caching of `rewardPerTokenStored` across an external call.
- **Ask:** after each update call, is every later read of the same state taken from storage?
- **Prove:** unit test: deposit into a pool with tiny supply after time has passed; compare `rewardDebt` against a recomputation from storage.

### Reward-rate and period arithmetic
- **Mechanism:** `notifyRewardAmount` sets `rewardRate = reward / duration`, which truncates (dust is stranded) and, when called mid-period, folds `leftover` in. Bugs: the balance check omits rewards earned-but-unclaimed, so the contract promises more than it holds and late claimers revert; `rewardsDuration` changed mid-period recomputes over the wrong remainder; a permissionless notify lets anyone add 1 wei and push `periodFinish` out, diluting the rate.
- **Where to look:** `notifyRewardAmount`, `setRewardsDuration`, `require(rewardRate <= balance / rewardsDuration)` and whether `balance` excludes staked principal when tokens coincide.
- **Ask:** who can call notify, with what minimum amount, and does each call extend the period?
- **Prove:** PoC: attacker calls `notifyRewardAmount(1)` repeatedly during an active period; assert stakers' reward at the original `periodFinish` drops. Property: invariant 3 after every notify.

### Rewards lost while total supply is zero
- **Mechanism:** Synthetix-style `rewardPerToken` returns the stored value when `totalSupply == 0`, but `lastUpdateTime` still advances, so rewards for that interval are never assigned and have no recovery path.
- **Where to look:** the zero-supply branch of `rewardPerToken`; whether notify can start a period with no stakers; whether a sweep function can recover undistributed rewards without touching owed ones.
- **Ask:** what happens to rewards for an interval with no stakers, and can the remainder be recovered or rolled into the next period?
- **Prove:** test: notify with zero stakers, warp half the period, stake, warp to end, claim; assert claimed + recoverable == notified (fails when the half-period is lost). Severity depends on recoverability: see [severity](skill://smart-contract-audit/references/methodology/severity.md).

### Precision loss in the accumulator
- **Mechanism:** `delta * rewardRate * 1e18 / totalSupply` rounds to 0 when the reward token has few decimals, the stake supply is large, and updates are frequent; an attacker who triggers an update every block (stake 1 wei, claim, or a permissionless notify of 0) suppresses distribution entirely, and `lastUpdateTime` still advances.
- **Where to look:** accumulator scaling factor vs reward-token decimals and maximum realistic supply; any permissionless function that runs `updateReward`.
- **Ask:** with a 6-decimal reward token, maximum supply, and a 1-block interval, is the per-update increment non-zero?
- **Prove:** unit test: stake large supply, notify USDC-like rewards, warp one block repeatedly with `updateReward` calls; assert `rewardPerToken` stays 0. Fix shape: scale by `1e18 * 10**(18 - rewardDecimals)` or carry the remainder.

### Same token for stake and reward
- **Mechanism:** `rewardToken.balanceOf(this)` includes staked principal; the notify check passes with no new funds, and claims pay out principal; `recoverERC20` that excludes only the staking token can still drain rewards (or vice versa).
- **Where to look:** constructor allowing `stakingToken == rewardsToken`, balance checks, sweep exclusions.
- **Ask:** in every balance-based check, is staked principal subtracted?
- **Prove:** PoC: notify without transferring reward tokens, then let stakers claim; assert the last withdrawer cannot recover principal.

### Flash staking and snapshot timing
- **Mechanism:** rewards or fee shares computed from a balance at a single moment (epoch end, snapshot, `distribute()` call) let an attacker deposit, trigger, and withdraw in one transaction. Also: deposit just before a known large notify and withdraw after.
- **Where to look:** `distribute`, `checkpoint`, `snapshot`, epoch-based `claim(epoch)` keyed on `balanceOf` at claim time instead of time-weighted balance; absence of a lock or minimum stake duration.
- **Ask:** is any payout proportional to a balance read at a single block that the claimant controls?
- **Prove:** PoC with a flash loan: stake, trigger distribution, claim, unstake, repay; assert profit.

### Epoch and Merkle claims
- **Mechanism:** claim for the same epoch twice (bitmap not set before transfer, or set under a different key), claim for a future or unfinalized epoch, Merkle leaf without `account` or `epoch`, root update that re-opens claimed leaves, claim-on-behalf that redirects the payout.
- **Where to look:** `claimed[epoch][account]` writes, leaf encoding (`abi.encodePacked` collisions; double hashing), root setters, `claimFor(receiver)`.
- **Ask:** is the leaf bound to account, amount, and epoch, and is the claimed flag set before the transfer in every path?
- **Prove:** PoC replaying a proof after a root update; property: per (epoch, account) at most one successful claim.

### Vote-escrow and lock manipulation
- **Mechanism:** `createLockFor`/`depositFor` lets a third party extend or add to a victim's lock (forcing lock time or griefing withdrawal); slope/bias checkpoints skip a week boundary so total supply drifts from the sum of balances; merge/split of NFT locks double-counts voting power within one block; boosts read current ve balance while rewards accrue over past time.
- **Where to look:** `_checkpoint`, `slopeChanges`, `increaseUnlockTime`, `merge`, `split`, boost formula in gauges, `balanceOfAt`/`totalSupplyAt`.
- **Ask:** can any party other than the owner change the owner's lock end or amount, and does `totalSupplyAt(t) == sum(balanceOfAt(user, t))` hold across week boundaries?
- **Prove:** stateful fuzz over lock operations with invariant 8; PoC voting with a lock, merging into another, and voting again in the same epoch.

### Multiple reward tokens
- **Mechanism:** unbounded reward-token list loops in every checkpoint (DoS once long); a reverting reward token (blocklisted user, paused token) blocks withdrawal of principal; removing a token strands earned rewards; adding the staking token as a reward token re-enables the same-token bug.
- **Where to look:** `addReward`, `for (i < rewardTokens.length)` inside `updateReward`, `getReward` looping transfers.
- **Ask:** can one reward token's failure block `withdraw` of principal?
- **Prove:** test with a reward token that reverts on transfer to the user; assert `withdraw` still succeeds.

### Non-standard staking token balances
- **Mechanism:** the contract credits `amount` on `stake` but receives less (fee-on-transfer), or the held balance drifts after deposit (rebasing up or down); `totalSupply` then disagrees with the token balance and the last withdrawer cannot exit, or rebase gains accrue to no one.
- **Where to look:** `stake` crediting the argument instead of `balanceAfter - balanceBefore`; rebasing tokens such as stETH accepted as stake (prefer the wrapped non-rebasing form).
- **Ask:** does every credited amount equal the balance delta actually received, and who owns balance growth that arrives without a deposit?
- **Prove:** test with a 1% fee-on-transfer mock: N users stake and all withdraw; assert the last `withdraw` reverts.

### Slashing, penalties, and early exit
- **Mechanism:** a slashing or penalty path reduces a user's stake without checkpointing their rewards first (rewards over-paid on the pre-slash balance); early-exit penalties redistributed to remaining stakers through the accumulator can be captured by a staker who enters just before a large exit; penalties sent back into the reward pool inflate `rewardRate` beyond the funded balance.
- **Where to look:** `slash`, `withdrawEarly`, `exitWithPenalty`, penalty redistribution (`notifyRewardAmount(penalty)` from inside the contract), vesting/escrow of claimed rewards (`vestingSchedules`, `lockedRewards`).
- **Ask:** is the penalized account checkpointed before its balance drops, and can anyone time an entry to capture a known redistribution?
- **Prove:** PoC: stake just before a whale's penalized exit, claim right after, unstake; assert the attacker's share of the penalty exceeds its time-weighted share.

### Reference checkpoint shape
Compare every balance-changing function against this ordering; any deviation is a lead for the missing-checkpoint class above.
```solidity
modifier updateReward(address account) {
    rewardPerTokenStored = rewardPerToken();
    lastUpdateTime = lastTimeRewardApplicable();
    if (account != address(0)) {
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
    _;
}
```

## Checklist items to walk

- Staking: SOL-Defi-Staking-1, SOL-Defi-Staking-2, SOL-Defi-Staking-3
- Accounting: SOL-Defi-General-3, SOL-Defi-General-8, SOL-AM-DA-1, SOL-Heuristics-11, SOL-Heuristics-13, SOL-Heuristics-16, SOL-Heuristics-17
- Math: SOL-Basics-Math-4, SOL-Basics-Math-5, SOL-Basics-Math-6, SOL-Heuristics-7, SOL-Heuristics-10, SOL-AM-DOSA-5
- Front-running and timing: SOL-AM-FrA-2, SOL-AM-FrA-3, SOL-AM-SandwichAttack-1, SOL-Defi-FlashLoan-1, SOL-AM-SybilAttack-1
- Liveness: SOL-AM-DOSA-1, SOL-AM-DOSA-2, SOL-AM-DOSA-3, SOL-AM-DOSA-6, SOL-Basics-AL-9, SOL-Basics-AL-10
- Reentrancy: SOL-EC-1, SOL-EC-13, SOL-AM-ReentrancyAttack-1, SOL-Token-FE-7
- Merkle claims: SOL-HMT-1, SOL-HMT-2, SOL-HMT-3, SOL-HMT-4, SOL-HMT-5, SOL-AM-ReplayAttack-1
- Admin: SOL-CR-4, SOL-CR-7, SOL-AM-RP-1
- Integrating external reward claims: SOL-Integrations-AC-7
- Token behavior: weird-ERC20 catalog ids B1, B4, B6, D1, D4, D5, E1, G4, G5 in [weird-erc20](skill://smart-contract-audit/references/weird-erc20.md); check both the staking token and every reward token.
- Whole categories: [upgradeability](skill://smart-contract-audit/references/upgradeability.md), [chain-specific](skill://smart-contract-audit/references/chain-specific.md) (block-number-based emissions on chains with variable block times).
- Governance power derived from stake: [governance playbook](skill://smart-contract-audit/references/playbooks/governance.md).

Proof tooling: [exploit PoC](skill://test-foundry/references/exploit-poc.md), [property catalog](skill://fuzz-echidna-medusa/references/property-catalog.md).

## Precedent

- **Cover Protocol Blacksmith, Dec 2020.** `deposit` read a `memory` copy of pool state after the storage update had changed `accRewardsPerToken`; the stale value set `rewardWriteoff` too low and the attacker minted an enormous amount of COVER. https://coverprotocol.medium.com/12-28-post-mortem-34c5f9f718d4 ; https://mudit.blog/cover-protocol-hack-analysis-tokens-minted-exploit/
- **Popsicle Finance, Aug 2021.** Share transfers skipped fee checkpoints for sender and receiver; the attacker moved the same shares across contracts and collected fees each time. https://blocksec.com/blog/the-analysis-of-the-popsicle-finance-security-incident ; https://www.halborn.com/blog/post/explained-the-popsicle-finance-hack-august-2021
- **Synthetix `StakingRewards` reference.** The canonical accumulator, notify, and zero-supply branch audited against above. https://github.com/Synthetixio/synthetix/blob/master/contracts/StakingRewards.sol
- **Zero-supply reward loss, Sherlock MakerDAO Endgame (2024) and Code4rena UniStaker (2024).** Rewards accrued while no one was staked were permanently stranded. https://github.com/sherlock-audit/2024-06-makerdao-endgame-judging/issues/96 ; https://github.com/code-423n4/2024-02-uniswap-foundation-findings/issues/112
- **Permissionless notify dilution, Code4rena Concur (2022) and Sherlock Symm.io (2025).** Anyone could call `notifyRewardAmount` with dust to stretch the period and dilute the rate. https://github.com/code-423n4/2022-02-concur-findings/issues/183 ; https://github.com/sherlock-audit/2025-03-symm-io-stacking-judging/issues/365
- **Low-decimal reward suppression, Sherlock Kwenta (2024) and Symm.io (2025).** Frequent updates rounded a 6-decimal reward accumulator increment to 0. https://github.com/sherlock-audit/2024-07-kwenta-staking-contracts-judging/issues/22 ; https://github.com/sherlock-audit/2025-03-symm-io-stacking-judging/issues/153
