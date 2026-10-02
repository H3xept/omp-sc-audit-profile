# Property catalog

Fuzzing properties for a Chimera/Recon tester, sorted by protocol type. Take every Cross-cutting row, add the section for each protocol type in scope, and keep a row only when the target has the state it names and the bug under **Catches** is reachable. Each row states the property as a falsifiable sentence, names the bug class that falsifies it (as the matching playbook names it), says where the check lives, gives a minimal snippet, and lists the handlers or ghosts it needs. Record each adopted row against its `INV-xxx` from `skill://smart-contract-audit/references/methodology/threat-model.md` Step 5, and rename `system`, `vault`, `market`, and the view names to the target's. A failing row becomes a finding through the triage steps in `skill://fuzz-echidna-medusa` and a reproducer per `skill://test-foundry/references/exploit-poc.md`.

Conventions the snippets assume (scaffold from `skill://recon-suite`):

- `invariant_*` and `property_*` live in `Properties` and never mutate state. Each `invariant_*` is declared `public returns (bool)` with no arguments and ends in `return true;`: Medusa's property provider runs it after every transaction only in that form, and the Chimera assertions inside still report under assertion mode. `doomsday_*` handlers live in `targets/DoomsdayTargets.sol` and carry `stateless`. Doomsday placement holds liveness checks (fail in `catch`) and stateless what-if sequences (round trips, preview against action), because `stateless` reverts their effects.
- `_before.x` / `_after.x` are `Vars` fields read in `__before` / `__after`; add each field a snippet names. `OpType` values (`DEPOSIT`, `SWAP`, `ADMIN`, …) come from `updateGhostsWithType(OpType.X)` on the handler.
- `ghost_*` are tester storage that a handler writes after a successful call (running totals, the last `from`/`to`/`amount`). When `__before` must read a chosen account, the outer handler sets that ghost first and then calls an internal function that carries `updateGhostsWithType(...) asActor`. Ghosts go first and the prank last, so the view calls in `__before` do not consume the prank.
- Sums loop over `_getActors()`. They are exact only when every holder is an actor: pick receivers with `_getActors()[between(idx, 0, n - 1)]`, never from a fuzzed address.
- Chimera `eq`/`gte`/`lte`/`gt`/`lt` take `uint256`. Compare signed values, addresses, and enums with `t(...)`. Narrow amount parameters to `uint128`, fold them with `between`, and discard unusable inputs with `precondition`.

Token behavior: run every asset-moving suite with the adversarial mocks in `AssetManager` rotation, and take their oracles from `skill://smart-contract-audit/references/weird-erc20.md` by id. Rows cite those ids and do not restate them. Section sources: [vaults](skill://smart-contract-audit/references/playbooks/vaults.md), [lending](skill://smart-contract-audit/references/playbooks/lending.md), [AMM](skill://smart-contract-audit/references/playbooks/amm-dex.md), [staking](skill://smart-contract-audit/references/playbooks/staking-rewards.md), [perps](skill://smart-contract-audit/references/playbooks/perps.md), [stablecoins](skill://smart-contract-audit/references/playbooks/stablecoins.md), [governance](skill://smart-contract-audit/references/playbooks/governance.md), [bridges](skill://smart-contract-audit/references/playbooks/bridges-messaging.md); LST and restaking systems combine the ERC4626 and Staking sections with [liquid staking](skill://smart-contract-audit/references/playbooks/liquid-staking.md).

## Cross-cutting

### PROP-XCUT-1: For every reachable state, the per-account balances the system records sum to the total it records.
- **Catches:** a path that writes a balance and not the total, or the reverse: a `_mint`/`_burn` override that skips one side, an `unchecked` underflow, a self-transfer that reads both balances before writing either.
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_sum_balances_eq_total() public returns (bool) {
      address[] memory a = _getActors(); uint256 s = system.balanceOf(address(system)) + system.balanceOf(DEAD);
      for (uint256 i; i < a.length; i++) s += system.balanceOf(a[i]);
      eq(s, system.totalSupply(), "sum(balances) != totalSupply");
      return true;
  }
  ```
- **Clamp/handlers:** every receiver comes from `_getActors()`. Add each protocol-held account (dead shares, fee recipient, treasury) to `s`.

### PROP-XCUT-2: Outside a callback, the token balance the system holds covers every liability it records.
- **Catches:** a liability booked with no inflow, a fee-on-transfer credit of the requested amount (weird-erc20 B1), a payout sent before its claim is decremented, fees counted both as reserve and as user assets.
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_solvency() public returns (bool) {
      gte(asset.balanceOf(address(system)) + system.deployedAssets(), system.totalUserClaims() + system.accruedFees(), "liabilities exceed holdings");
      return true;
  }
  ```
- **Clamp/handlers:** without a claims getter, loop actors over the per-account claim view. `deployedAssets` is the recorded amount lent out or held by strategies; use 0 when none exists.

### PROP-XCUT-3: A privileged parameter, owner, or role changes only in a call made by the privileged account.
- **Catches:** a missing modifier, a re-callable `initialize`, a role grant or `upgradeTo` reachable through a multicall or arbitrary-call path (`skill://smart-contract-audit/references/arbitrary-calls-approvals.md`).
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_admin_state_only_by_admin() public {
      if (currentOperation == OpType.ADMIN) return;
      eq(_before.feeBps, _after.feeBps, "fee changed by non-admin");
      t(_before.owner == _after.owner && _before.rolesHash == _after.rolesHash, "owner or roles changed by non-admin");
  }
  ```
- **Clamp/handlers:** privileged handlers use `updateGhostsWithType(OpType.ADMIN) asAdmin`. Expose every privileged function a second time as an `updateGhosts asActor` handler, so non-admin attempts run. `rolesHash` is `keccak256` over `hasRole(role, actor)` for every role and actor.

### PROP-XCUT-4: No nonce, accumulator index, or executed-message count ever decreases.
- **Catches:** signature replay after a nonce reset or a downcast (`uint64(nonce)`), an index update with the wrong sign, an executed flag cleared by a `retry` or `cancel` path.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_counters_monotonic() public {
      gte(_after.nonce, _before.nonce, "nonce decreased");
      gte(_after.index, _before.index, "index decreased");
      gte(_after.executedCount, _before.executedCount, "executed set shrank");
  }
  ```
- **Clamp/handlers:** add a warp handler, `vm.warp(block.timestamp + between(dt, 1, 30 days))`, so accrual paths run. `__before` and `__after` read the nonce of `_getActor()`.

### PROP-XCUT-5: An actor with a positive claim can always exit it while the system is not paused.
- **Catches:** an underflow in fee or withdrawal math, a stale cache after a donation, an unbounded loop, an admin parameter that freezes exits, a reward token that reverts and blocks principal (weird-erc20 D4, D5).
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_exit_never_reverts() public stateless {
      address a = _getActor(); uint256 c = system.claimOf(a);
      precondition(c > 0 && !system.paused());
      vm.prank(a); try system.withdraw(c) {} catch { t(false, "funded actor cannot exit"); }
  }
  ```
- **Clamp/handlers:** for ERC-4626 set `c = vault.maxWithdraw(a)`; the row then also tests `max*` honesty (vaults: Withdrawal liquidity and `max*` honesty). Add pausable or blocklist mocks only when the support policy says exits must survive them.

### PROP-XCUT-6: A view that quotes an action returns what the action does in the same state.
- **Catches:** a quote that omits a fee, a cap, or interest accrual, so integrators that size from it revert or overpay; a quote that reads state the action updates first.
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_quote_matches_action(uint128 amt) public stateless {
      address a = _getActor(); uint256 x = between(amt, 1, token.balanceOf(a)); uint256 q = system.quote(x);
      vm.prank(a); eq(system.act(x), q, "quote != action result");
  }
  ```
- **Clamp/handlers:** `precondition(token.balanceOf(a) > 0)` before `between`. Where the spec allows the quote to be conservative, replace `eq` with the allowed direction (PROP-VAULT-3).

## ERC20

### PROP-ERC20-1: A transfer debits the sender and credits the receiver by exactly the amount, and a self-transfer changes no balance.
- **Catches:** a fee or burn hidden in `_update`, reflection logic, a self-transfer that caches both balances and credits twice.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_transfer_exact() public {
      if (currentOperation != OpType.TRANSFER) return; eq(_after.supply, _before.supply, "transfer moved supply");
      if (ghost_from == ghost_to) { eq(_after.balFrom, _before.balFrom, "self-transfer changed balance"); return; }
      eq(_before.balFrom - _after.balFrom, ghost_amount, "debit != amount"); eq(_after.balTo - _before.balTo, ghost_amount, "credit != amount");
  }
  ```
- **Clamp/handlers:** `token_transfer(uint256 toIdx, uint128 amt)` sets `ghost_from`, `ghost_to`, `ghost_amount`, then calls an internal `_transfer` with `updateGhostsWithType(OpType.TRANSFER) asActor`. Allow `toIdx` to select the sender.

### PROP-ERC20-2: `transferFrom` lowers the allowance by exactly the amount unless the allowance is the maximum.
- **Catches:** a skipped `_spendAllowance`, allowance spent from the wrong (owner, spender) pair, a max allowance decremented against the stated policy (weird-erc20 C2).
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_allowance_spent_exactly() public {
      if (currentOperation != OpType.TRANSFER_FROM || _before.allowance == type(uint256).max) return;
      eq(_before.allowance - _after.allowance, ghost_amount, "allowance not spent by amount");
  }
  ```
- **Clamp/handlers:** add `token_approve(uint256 spenderIdx, uint128 amt)`; the spender of `transferFrom` is another actor, pranked as spender.

### PROP-ERC20-3: The amount the system credits on an inflow equals the change in its token balance.
- **Catches:** crediting `amount` instead of the measured delta for a fee-on-transfer token (weird-erc20 B1, D8), a callback that re-enters the credit path before the first credit settles (E1).
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_credit_eq_received() public {
      if (currentOperation != OpType.DEPOSIT) return;
      eq(_after.recorded - _before.recorded, _after.held - _before.held, "credit != tokens received (weird-erc20 B1)");
  }
  ```
- **Clamp/handlers:** `_addAsset(address(new MockFoTToken()))` in `setup()` plus a `switch_asset` handler. `held` is `_getAsset().balanceOf(address(system))`; `recorded` is the system's internal total for that asset.

### PROP-ERC20-4: A positive rebase of a held token never lowers what the system reports it owns, and after a negative rebase it reports no more than it holds.
- **Catches:** a cached balance that ignores rebases (weird-erc20 B4, B5), a `skim`-style path that captures the rebase for one caller, solvency logic that assumes balances only grow (B6).
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_rebase_tracked() public {
      if (currentOperation == OpType.REBASE_UP) gte(_after.reported, _before.reported, "positive rebase lowered reported assets");
      if (currentOperation == OpType.REBASE_DOWN) lte(_after.reported, _after.held, "reports more than held after negative rebase");
  }
  ```
- **Clamp/handlers:** rebasing mock per the weird-erc20 recipe with `token_rebase(uint16 bps, bool up)` under `updateGhostsWithType`; `bps = between(bps, 1, 5_000)`. When the design syncs on the next call, move the second assert to the next `DEPOSIT` or `WITHDRAW`.

## ERC4626 and yield vaults

### PROP-VAULT-1: The share price never decreases except through a booked loss.
- **Catches:** rounding toward the user in `withdraw` or `mint` (Rounding and preview mismatches), fee shares minted at a stale price (Fee accounting), a strategy loss realized but not booked (Emergency shutdown, migration, and upgrades).
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_share_price_monotonic() public {
      if (currentOperation == OpType.LOSS) return;
      gte(_after.pricePerShare, _before.pricePerShare, "share price fell without a loss");
  }
  ```
- **Clamp/handlers:** `pricePerShare = vault.convertToAssets(10 ** vault.decimals())`. A `strategy_loss(uint16 bps)` handler uses `updateGhostsWithType(OpType.LOSS)`. Set the management fee to 0, or tag fee accrual as its own `OpType`, since time-based fees dilute the price by design.

### PROP-VAULT-2: A deposit followed by a full redeem in the same transaction returns at most the deposited assets.
- **Catches:** rounding that favors the user on either leg, a withdrawal fee missing from one path, a `totalAssets` that a deposit itself raises (Manipulable `totalAssets`).
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_roundtrip_no_profit(uint128 assets) public stateless {
      address a = _getActor(); precondition(asset.balanceOf(a) > 0); uint256 x = between(assets, 1, asset.balanceOf(a));
      vm.prank(a); uint256 s = vault.deposit(x, a);
      vm.prank(a); lte(vault.redeem(s, a, a), x, "deposit -> redeem returned more than deposited");
  }
  ```
- **Clamp/handlers:** run after donation, loss, and harvest handlers have moved the price; the row is valuable only in non-trivial states.

### PROP-VAULT-3: Each preview bounds its action in the vault's favor: `previewDeposit <= deposit`, `previewMint >= mint`, `previewWithdraw >= withdraw`, `previewRedeem <= redeem`.
- **Catches:** previews that omit fees or limits, rounding direction swapped between the preview and the action (Rounding and preview mismatches; vaults invariant 3).
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_preview_redeem_bound(uint128 shares) public stateless {
      address a = _getActor(); precondition(vault.balanceOf(a) > 0); uint256 s = between(shares, 1, vault.balanceOf(a));
      uint256 p = vault.previewRedeem(s); vm.prank(a); gte(vault.redeem(s, a, a), p, "redeem paid < previewRedeem");
  }
  ```
- **Clamp/handlers:** write one handler per action with the inequality direction above; `mint` and `withdraw` compare the assets pulled or the shares burned, measured as balance deltas.

### PROP-VAULT-4: In an empty vault, an attacker who deposits, donates, and redeems around a victim's deposit ends with no more assets than at the start.
- **Catches:** first-depositor / donation inflation: a missing virtual offset or dead shares, a zero-share deposit accepted.
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_no_inflation_profit(uint128 donation, uint128 victim) public stateless {
      precondition(vault.totalSupply() == 0); address atk = _getActors()[1]; address vic = _getActors()[2]; uint256 start = asset.balanceOf(atk);
      vm.prank(atk); vault.deposit(1, atk); vm.prank(atk); asset.transfer(address(vault), between(donation, 1, start - 1));
      vm.prank(vic); vault.deposit(between(victim, 1, asset.balanceOf(vic)), vic);
      vm.prank(atk); vault.redeem(vault.balanceOf(atk), atk, atk); lte(asset.balanceOf(atk), start, "inflation attack profitable");
  }
  ```
- **Clamp/handlers:** needs at least three actors. Each fuzz sequence starts from the post-`setup()` state, so the empty-vault precondition holds at the start of every sequence.

## Lending

### PROP-LEND-1: After any call that raises the caller's risk, the caller has no shortfall.
- **Catches:** a missing health check on a balance-reducing path (Euler `donateToReserves`), a check that reads a stale price or an unaccrued index.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_risk_up_leaves_caller_healthy() public {
      if (currentOperation == OpType.RISK_UP) eq(_after.actorShortfall, 0, "risk-increasing call left caller in shortfall");
  }
  ```
- **Clamp/handlers:** tag `borrow`, `redeem`/`withdraw`, collateral disable, share transfer out, and every function that burns the caller's supply shares as `RISK_UP`. `__after` reads `(, , shortfall) = comptroller.getAccountLiquidity(_getActor())`, or the target's health view.

### PROP-LEND-2: The debt of all borrowers sums to `totalBorrows` within one unit per borrower.
- **Catches:** interest accrual ordering (one path skips `accrueInterest`), debt shares minted rounding down (Rounding direction in share and debt conversion), bad debt removed from a user but not from the total.
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_debt_sum_matches_total() public returns (bool) {
      address[] memory a = _getActors(); uint256 s; uint256 tb = market.totalBorrows();
      for (uint256 i; i < a.length; i++) s += market.borrowBalanceStored(a[i]);
      lte(s > tb ? s - tb : tb - s, a.length, "user debt diverges from totalBorrows");
      return true;
  }
  ```
- **Clamp/handlers:** every handler calls `market.accrueInterest()` first, so both sides are stored at the same index. Add a warp handler.

### PROP-LEND-3: `borrowIndex` never decreases, and the supply exchange rate never decreases except when bad debt is realized.
- **Catches:** empty-market share inflation, where `redeemUnderlying` rounds burned shares down and lowers the rate (Hundred Finance); supply shares rounding toward the user; bad debt hidden in the exchange rate.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_indices_monotonic() public {
      gte(_after.borrowIndex, _before.borrowIndex, "borrowIndex decreased");
      if (currentOperation != OpType.BAD_DEBT) gte(_after.exchangeRate, _before.exchangeRate, "exchange rate fell without bad debt");
  }
  ```
- **Clamp/handlers:** list one market with zero supply in `setup()`, and add a donation handler (`underlying.transfer(address(market), amt)`). The exploit needs a near-empty market.

### PROP-LEND-4: A position in shortfall is liquidatable for any repay amount the close factor and its collateral allow.
- **Catches:** liquidation blocked or front-run: a pause that blocks liquidation but not accrual, a reverting token hook or blocklist (weird-erc20 D4, E1), an exact-amount repay that a tiny front-run repay makes fail.
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_shortfall_is_liquidatable(uint256 idx, uint128 repay) public stateless {
      address[] memory a = _getActors(); address b = a[between(idx, 0, a.length - 1)]; (, , uint256 sf) = comptroller.getAccountLiquidity(b);
      uint256 maxR = market.borrowBalanceStored(b) * comptroller.closeFactorMantissa() / 1e18; precondition(sf > 0 && b != _getActor() && maxR > 0);
      vm.prank(_getActor()); try market.liquidateBorrow(b, between(repay, 1, maxR), collateralMarket) returns (uint256 err) { eq(err, 0, "liquidation error code"); } catch { t(false, "shortfall position not liquidatable"); }
  }
  ```
- **Clamp/handlers:** add `oracle_setPrice(uint8 i, uint16 bps)` moving prices by up to ±50%, so shortfalls occur. Also precondition the seize amount from `comptroller.liquidateCalculateSeizeTokens` to be within the borrower's collateral; beyond that the state is bad debt. Compound v2 returns error codes instead of reverting, so check `err`.

### PROP-LEND-5: A liquidation that leaves debt open never lowers the borrower's health factor.
- **Catches:** liquidation math and incentives: a bonus larger than the collateral cushion, seize computed in the wrong decimals, repeated partial liquidations that each worsen the position.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_liquidation_improves_health() public {
      if (currentOperation != OpType.LIQUIDATE || _after.borrowerDebt == 0) return;
      gte(_after.borrowerHF, _before.borrowerHF, "liquidation lowered borrower health");
  }
  ```
- **Clamp/handlers:** the liquidate handler sets `ghost_borrower`, then calls an internal function with `updateGhostsWithType(OpType.LIQUIDATE) asActor`. `borrowerHF` is the target's health factor in 1e18 (Aave: the sixth return of `getUserAccountData`).

## AMM

### PROP-AMM-1: A swap never decreases the product of the reserves.
- **Catches:** an invariant check scaled inconsistently (Uranium's 10000 against `1000**2`), amount math rounding toward the trader.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_swap_k_nondecreasing() public {
      if (currentOperation == OpType.SWAP) gte(_after.reserve0 * _after.reserve1, _before.reserve0 * _before.reserve1, "swap decreased k");
  }
  ```
- **Clamp/handlers:** the swap handler sends a fuzzed input to the pair and requests `amountOut = between(out, 1, reserveOut - 1)`, so the pool's own k check is the only guard. Reserves are `uint112`, so the product fits `uint256`.

### PROP-AMM-2: Stored reserves never exceed the pool's token balances.
- **Catches:** reserves versus balances bugs (`sync`/`skim` ordering), a pool that credits the requested amount of a fee-on-transfer token (weird-erc20 B1), a negative rebase of a pool token (B6).
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_reserves_le_balances() public returns (bool) {
      (uint112 r0, uint112 r1, ) = pair.getReserves();
      lte(r0, token0.balanceOf(address(pair)), "reserve0 > balance0"); lte(r1, token1.balanceOf(address(pair)), "reserve1 > balance1");
      return true;
  }
  ```
- **Clamp/handlers:** include `pair_sync`, `pair_skim`, and a donation handler that transfers tokens straight to the pair.

### PROP-AMM-3: A swap followed by its exact reverse never returns more than the original input.
- **Catches:** rounding direction in price and amount math (Balancer v2 exact-out rounding, Bunni v2 withdraw rounding), tick crossing that updates the tick and not the liquidity (KyberSwap Elastic).
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_swap_roundtrip_no_profit(uint128 amountIn) public stateless {
      address a = _getActor(); precondition(token0.balanceOf(a) > 0); uint256 x = between(amountIn, 1, token0.balanceOf(a));
      vm.prank(a); uint256 mid = router.swapExactIn(token0, token1, x, 0, a);
      vm.prank(a); lte(router.swapExactIn(token1, token0, mid, 0, a), x, "swap round trip profited");
  }
  ```
- **Clamp/handlers:** add-liquidity handlers place positions across several tick ranges first, so round trips cross initialized ticks.

### PROP-AMM-4: In a concentrated-liquidity pool, active liquidity equals the sum of `liquidityNet` over every initialized tick at or below the current tick.
- **Catches:** tick crossing and liquidity accounting: a swap step that ends past an initialized tick without crossing it (KyberSwap Elastic), a burn that clears the bitmap bit while `liquidityGross` stays non-zero.
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_active_liquidity_matches_ticks() public returns (bool) {
      (, int24 cur, , , , , ) = pool.slot0(); int256 s;
      for (uint256 i; i < ghost_ticks.length; i++) if (ghost_ticks[i] <= cur) { (, int128 net, , , , , , ) = pool.ticks(ghost_ticks[i]); s += net; }
      t(s == int256(uint256(pool.liquidity())), "active liquidity != sum(liquidityNet) at or below tick");
      return true;
  }
  ```
- **Clamp/handlers:** the mint handler clamps ticks to multiples of `tickSpacing` inside `[MIN_TICK, MAX_TICK]` and pushes each new tick into `ghost_ticks` once. Use the Uniswap v3 tuple shapes shown; adapt them for forks.

## Staking and rewards

### PROP-STAKE-1: Rewards claimed plus rewards still earned never exceed rewards notified.
- **Catches:** a missing or misordered checkpoint (Popsicle share transfers), a stale cached accumulator (Cover Blacksmith), a double claim on an epoch or Merkle path.
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_rewards_bounded_by_notified() public returns (bool) {
      address[] memory a = _getActors(); uint256 s = ghost_claimedTotal;
      for (uint256 i; i < a.length; i++) s += staking.earned(a[i]);
      lte(s, ghost_notifiedTotal, "claimed + earned > notified");
      return true;
  }
  ```
- **Clamp/handlers:** the notify handler (`asAdmin`) adds the measured received amount to `ghost_notifiedTotal`. The claim handler adds the claimant's measured balance delta to `ghost_claimedTotal`. When `stakingToken == rewardToken` is allowed, also run a suite with that configuration (Same token for stake and reward).

### PROP-STAKE-2: Two accounts that stake the same amount at the same time earn the same reward within one wei per claim, however often one of them claims.
- **Catches:** a checkpoint that `getReward` resets wrongly, `rewards[account]` overwritten instead of accumulated, per-user rounding that compounds with claim frequency.
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_equal_stakes_earn_equally() public returns (bool) {
      uint256 x = staking.earned(SHADOW_A) + ghost_claimedShadowA; uint256 y = staking.earned(SHADOW_B);
      lte(x > y ? x - y : y - x, ghost_shadowAClaims + 1, "claim frequency changed reward");
      return true;
  }
  ```
- **Clamp/handlers:** two shadow accounts, kept out of `_getActors()`, stake equal amounts in `setup()`. Only `shadow_claimA()` touches them: it claims for `SHADOW_A`, adds the delta to `ghost_claimedShadowA`, and increments `ghost_shadowAClaims`.

### PROP-STAKE-3: Moving stake between two accounts in one call leaves the sum of their earned rewards unchanged.
- **Catches:** a missing checkpoint on receipt-token transfer, delegation, merge, or split; the receiver then earns the whole past interval on the new balance.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_stake_transfer_conserves_rewards() public {
      if (currentOperation != OpType.STAKE_TRANSFER) return;
      uint256 b = _before.earnedFrom + _before.earnedTo; uint256 c = _after.earnedFrom + _after.earnedTo;
      lte(c > b ? c - b : b - c, 1, "stake transfer created or destroyed rewards");
  }
  ```
- **Clamp/handlers:** the transfer handler sets `ghost_from` and `ghost_to` before the internal call with `updateGhostsWithType(OpType.STAKE_TRANSFER) asActor`. Run it after warps, so `rewardPerToken` has moved since each account's last checkpoint.

### PROP-STAKE-4: After a reward period ends, claimed plus earned plus recoverable rewards equal the notified total within the documented truncation dust.
- **Catches:** rewards lost while total supply is zero; precision loss in the accumulator, where frequent updates round each increment to 0 (Sherlock Kwenta 2024, Symm.io 2025); a `rewardsDuration` change that strands the remainder.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_period_fully_distributed() public {
      precondition(block.timestamp > staking.periodFinish() && ghost_notifiedTotal > 0); address[] memory a = _getActors();
      uint256 s = ghost_claimedTotal + staking.recoverable(); for (uint256 i; i < a.length; i++) s += staking.earned(a[i]);
      gte(s + ghost_notifyCount * staking.rewardsDuration() + ghost_updates * (ghost_maxSupply / 1e18 + 2), ghost_notifiedTotal, "notified rewards lost");
  }
  ```
- **Clamp/handlers:** `recoverable()` is the sweepable remainder, or 0 when no recovery path exists. Every handler that runs `updateReward` increments `ghost_updates`; stake handlers track `ghost_maxSupply`. The dust bound is `reward % duration` per notify, under `supply / 1e18` per accumulator update, and 1 wei per checkpointed account (at most two per update). Run one suite with a 6-decimal reward token (weird-erc20 G4).

## Perpetuals

### PROP-PERP-1: The collateral the exchange holds covers the positive equity of every trader plus the insurance fund, LP equity, and fees.
- **Catches:** PnL or funding credited to both sides, fees booked both as revenue and as margin, LP equity that counts an uncollectable trader loss (bad debt not recognized).
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_collateral_covers_equity() public returns (bool) {
      address[] memory a = _getActors(); uint256 owed = perp.insuranceFund() + perp.lpEquity() + perp.accruedFees();
      for (uint256 i; i < a.length; i++) { int256 e = int256(perp.marginOf(a[i])) + perp.unrealizedPnl(a[i]) - perp.pendingFunding(a[i]); if (e > 0) owed += uint256(e); }
      gte(collateral.balanceOf(address(perp)), owed, "claims exceed collateral held");
      return true;
  }
  ```
- **Clamp/handlers:** the oracle handler moves the price at most ±5% per call, so liquidations can keep up. Without that bound, a legitimate gap past the insurance fund fires the row.

### PROP-PERP-2: After any call that raises a trader's risk, the position meets the initial margin requirement.
- **Catches:** a margin check missing on collateral removal or on a size increase, a check run before the fee is deducted, a check against a stale or caller-supplied price.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_risk_up_meets_initial_margin() public {
      if (currentOperation != OpType.RISK_UP) return;
      gte(_after.actorEquity, _after.actorInitialMargin, "risk-increasing call left position under initial margin");
  }
  ```
- **Clamp/handlers:** tag open, increase, collateral withdrawal, and transfer of margin between accounts as `RISK_UP`. `actorEquity` clamps negative equity to 0 in `__after`.

### PROP-PERP-3: A position below maintenance margin is always liquidatable.
- **Catches:** liquidation blocked by a minimum-size or slippage check, a stale-oracle revert that only fires on the liquidation path, an insurance-fund underflow, a reverting trader callback.
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_underwater_is_liquidatable(uint256 idx) public stateless {
      address[] memory a = _getActors(); address b = a[between(idx, 0, a.length - 1)];
      precondition(perp.isLiquidatable(b) && b != _getActor());
      vm.prank(_getActor()); try perp.liquidate(b) {} catch { t(false, "underwater position not liquidatable"); }
  }
  ```
- **Clamp/handlers:** the same bounded oracle handler as PROP-PERP-1. For keeper-only liquidation, prank the keeper role.

### PROP-PERP-4: Opening and closing a position at an unchanged oracle price never returns more collateral than the trader deposited.
- **Catches:** PnL sign or rounding toward the trader, price impact charged on open but refunded in full on close, fees computed on the wrong notional.
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_open_close_no_profit(uint128 margin, int128 size) public stateless {
      address a = _getActor(); uint256 start = collateral.balanceOf(a); uint256 m = between(margin, 1, start);
      vm.startPrank(a); perp.deposit(m); perp.openPosition(int256(size)); perp.closePosition(); perp.withdraw(perp.marginOf(a)); vm.stopPrank();
      lte(collateral.balanceOf(a), start, "open-close round trip profited");
  }
  ```
- **Clamp/handlers:** `precondition(start > 0 && size != 0)`. For two-step orders, run the keeper execution for both legs inside the handler at the same oracle price.

## Stablecoins

### PROP-STABLE-1: Stablecoin supply never exceeds recorded debt plus the supply minted against reserves.
- **Catches:** a mint path that records no debt, a repay that burns less than the debt it clears, a liquidation that cancels debt without burning stablecoin.
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_supply_backed_by_debt() public returns (bool) {
      lte(stable.totalSupply(), engine.totalDebt() + psm.mintedViaPsm() + ghost_otherAuthorizedMints, "stablecoin minted without recorded debt");
      return true;
  }
  ```
- **Clamp/handlers:** accrued stability fees raise `totalDebt` above supply by design, which is why the check is `lte`. Add a second invariant: the sum of per-vault debt equals `totalDebt` within one unit per vault.

### PROP-STABLE-2: A peg-stability module holds reserves worth at least the stablecoin it minted, after decimal scaling.
- **Catches:** 6-decimal reserve scaling errors (weird-erc20 G4), buy and sell fees rounded toward the user, a swap path that mints before the reserve transfer settles.
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_psm_backed() public returns (bool) {
      gte(gem.balanceOf(address(psm)) * 10 ** (18 - gem.decimals()), psm.mintedViaPsm(), "PSM reserves below minted supply");
      return true;
  }
  ```
- **Clamp/handlers:** `psm_sell(uint128)` and `psm_buy(uint128)` handlers; deploy the reserve mock with 6 decimals.

### PROP-STABLE-3: A redemption pays the redeemer no more collateral than the burned stablecoin is worth at the oracle price.
- **Catches:** redemption against an inverted or stale price, a missing redemption fee, rounding toward the redeemer, a redemption that takes collateral from a vault without reducing its debt.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_redemption_at_or_below_face() public {
      if (currentOperation != OpType.REDEEM) return;
      lte((_after.redeemerColl - _before.redeemerColl) * oracle.price() / 1e18, ghost_burned, "redemption paid above face value");
  }
  ```
- **Clamp/handlers:** `oracle.price()` is stablecoin per collateral unit in 1e18. The redeem handler records `ghost_burned` as the measured drop in the redeemer's stablecoin balance.

### PROP-STABLE-4: A vault below the minimum collateral ratio is always liquidatable.
- **Catches:** liquidation that depends on a stability pool with no fallback path, a price-feed revert that only fires on the liquidation path, a corrupted sorted-vault list that skips the riskiest vault.
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_under_mcr_liquidatable(uint256 idx) public stateless {
      address[] memory a = _getActors(); address v = a[between(idx, 0, a.length - 1)];
      precondition(engine.debtOf(v) > 0 && engine.collateralRatio(v) < engine.MCR());
      vm.prank(_getActor()); try engine.liquidate(v) {} catch { t(false, "vault under MCR not liquidatable"); }
  }
  ```
- **Clamp/handlers:** add an oracle handler with bounded moves, plus handlers that empty the stability pool, so the fallback path runs.

## Governance and timelock

### PROP-GOV-1: `getPastVotes(account, t)` returns the same value for every query made after `t`.
- **Catches:** a checkpoint pushed twice in one timepoint instead of overwritten, a binary-search boundary error, a clock-mode switch over existing checkpoints (Delegation and checkpoint accounting; Clock and snapshot timing).
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_past_votes_immutable() public returns (bool) {
      for (uint256 i; i < ghost_past.length; i++) {
          eq(token.getPastVotes(ghost_past[i].account, ghost_past[i].timepoint), ghost_past[i].votes, "vote history rewritten");
      }
      return true;
  }
  ```
- **Clamp/handlers:** `gov_recordPast()` stores `(actor, token.clock() - 1, getPastVotes(actor, clock() - 1))`, capped at about 64 entries. Add warp and roll handlers that move both clocks.

### PROP-GOV-2: Delegated voting power summed over every delegatee equals the balance held by accounts that have a delegatee.
- **Catches:** delegation and checkpoint accounting errors: SushiToken's `_moveDelegates(from, to)` instead of the delegatees, a mint or burn override that skips the votes hook, a balance change with no vote move (weird-erc20 B1, B4).
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_delegation_conserved() public returns (bool) {
      address[] memory a = _getActors(); uint256 votes; uint256 delegated;
      for (uint256 i; i < a.length; i++) { votes += token.getVotes(a[i]); if (token.delegates(a[i]) != address(0)) delegated += token.balanceOf(a[i]); }
      eq(votes, delegated, "sum(votes) != delegated balance");
      return true;
  }
  ```
- **Clamp/handlers:** the delegate handler picks delegatees from `_getActors()`; add transfer, mint, burn, and self-delegate handlers.

### PROP-GOV-3: The weight a vote adds to a proposal equals the voter's `getPastVotes` at that proposal's snapshot.
- **Catches:** flash-loan and same-block voting power (Beanstalk), a Governor and token on different clocks, double voting by moving weight between accounts or veNFTs.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_vote_weight_at_snapshot() public {
      if (currentOperation != OpType.VOTE) return;
      eq(_after.totalCast - _before.totalCast, token.getPastVotes(ghost_voter, governor.proposalSnapshot(ghost_proposalId)), "vote weight != snapshot weight");
  }
  ```
- **Clamp/handlers:** `totalCast` is for + against + abstain from `proposalVotes(ghost_proposalId)`. The vote handler sets `ghost_voter` and `ghost_proposalId` first. A `gov_flashVote` handler mints, votes, and burns in one call.

### PROP-GOV-4: A proposal executes only from the Queued state at or after its eta, and at most once.
- **Catches:** timelock bypass through a fast-track or guardian path (Beanstalk `emergencyCommit`), `minDelay = 0`, re-execution after an operation id collision, a canceled proposal still executable in the timelock.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_execute_after_queue_and_delay() public {
      if (currentOperation != OpType.EXECUTE) return;
      t(_before.state == uint8(IGovernor.ProposalState.Queued), "executed a proposal that was not queued");
      gte(block.timestamp, _before.eta, "executed before eta"); eq(ghost_executions[ghost_proposalId], 1, "proposal executed twice");
  }
  ```
- **Clamp/handlers:** add handlers for propose, vote, queue, execute, cancel, and warp. Proposals target a mock with one call. The execute handler increments `ghost_executions[id]` after success. Pair with PROP-XCUT-3 tagging timelock execution as `ADMIN`.

## Bridges and messaging

Harness: one chain hosts both ends; a mock endpoint queues sent packets, and handlers deliver, drop, duplicate, reorder, or fail them.

### PROP-BRIDGE-1: The source escrow holds at least the wrapped supply plus every in-flight amount.
- **Catches:** escrow, mint authority, and deposit-integrity bugs (Qubit's codeless `safeTransferFrom` deposit), a fee-on-transfer or rebasing token behind a lock adapter (weird-erc20 B1, B4), a double mint on redelivery.
- **Placement:** `invariant_*`
- **Snippet:**
  ```solidity
  function invariant_escrow_covers_wrapped() public returns (bool) {
      gte(token.balanceOf(address(adapter)), wrapped.totalSupply() + ghost_inFlightToDst + ghost_inFlightToSrc, "wrapped supply exceeds escrow");
      return true;
  }
  ```
- **Clamp/handlers:** the send handlers add amounts to the in-flight ghosts, and the delivery handlers subtract them. Rotate a fee-on-transfer asset into the adapter.

### PROP-BRIDGE-2: Every message the destination executes was dispatched by the registered source peer.
- **Catches:** default-value proof acceptance (Nomad zero root), missing sender authentication on the receiver, a signature or threshold check that accepts duplicates or `address(0)`.
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_executed_implies_dispatched() public {
      if (currentOperation == OpType.DELIVER) t(ghost_dispatched[ghost_lastGuid], "executed a message the source never sent");
  }
  ```
- **Clamp/handlers:** the deliver handler uses `between(choice, 0, 1)` to pick a queued packet or a forged one (fuzzed `srcEid`, sender, nonce, payload, empty proof). It sets `ghost_lastGuid` to the delivered packet's guid.

### PROP-BRIDGE-3: Delivering an already executed message again credits nothing.
- **Catches:** replay and double execution: an executed flag keyed on a hash without nonce or chain, a flag written after the external call, a `retryMessage` that runs the payload before deleting it.
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_redelivery_credits_nothing(uint256 i) public stateless {
      precondition(ghost_executed.length > 0); Packet memory p = ghost_executed[between(i, 0, ghost_executed.length - 1)]; uint256 bal = wrapped.balanceOf(p.to);
      try endpoint.redeliver(p) {} catch {} eq(wrapped.balanceOf(p.to), bal, "message executed twice");
  }
  ```
- **Clamp/handlers:** the deliver handler appends each executed packet to `ghost_executed`. Add a `retryMessage` handler for failed packets.

### PROP-BRIDGE-4: The destination credits at most the amount debited on the source, and the difference is below one shared-decimal unit.
- **Catches:** amount and decimals conversion bugs: OFT `_toSD` truncation above `uint64`, dust burned instead of left with the sender, decimal mismatch between ends (weird-erc20 G4, G5).
- **Placement:** `property_*`
- **Snippet:**
  ```solidity
  function property_credit_matches_debit() public {
      if (currentOperation != OpType.DELIVER) return; bytes32 g = ghost_lastGuid;
      lte(ghost_credited[g], ghost_debited[g], "credited more than debited"); lt(ghost_debited[g] - ghost_credited[g], 10 ** (localDecimals - sharedDecimals), "lost more than dust");
  }
  ```
- **Clamp/handlers:** the send handler takes `uint128 amountLD` unbounded, so values above `uint64` shared units occur. Deploy separate setups with local decimals 6, 8, 18, and 24.

### PROP-BRIDGE-5: A message that fails for one user never blocks delivery of another user's message.
- **Catches:** channel blocking and ordering: a LayerZero V1 blocking receiver, ordered execution with no unblock path, destination gas below what the handler needs.
- **Placement:** doomsday handler
- **Snippet:**
  ```solidity
  function doomsday_failure_isolated(uint256 i) public stateless {
      precondition(ghost_failedCount > 0 && ghost_pending.length > 0); Packet memory p = ghost_pending[between(i, 0, ghost_pending.length - 1)];
      precondition(p.sender != ghost_lastFailedSender); try endpoint.deliver(p) {} catch { t(false, "one failed message blocks another user"); }
  }
  ```
- **Clamp/handlers:** a `bridge_fail(i)` handler delivers a packet with too little gas, or to a reverting receiver, and records its sender. Packets in `ghost_pending` must be valid on their own.
