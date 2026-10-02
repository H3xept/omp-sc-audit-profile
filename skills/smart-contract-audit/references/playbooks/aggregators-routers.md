# Aggregators and routers playbook

Load when: the code holds or pulls user approvals and then executes a caller-described route (`calls[]`, `swapData`, `route` bytes, `target`+`data`, facet dispatch), multi-hops across DEXes, settles signed orders or intents through solvers/resolvers, or starts a bridge transfer with destination calldata.

## Core invariants

1. The router moves a user's tokens only on that user's behalf: every `transferFrom(from, ...)` takes `from == msg.sender` or a verified signer of the current order.
2. Between transactions the router holds zero balance and zero outstanding allowance to any target, except documented fee balances.
3. The user receives at least `minAmountOut` of the final token, measured as the recipient's balance increase.
4. Every unit of input is swapped, refunded to the user, or taken as a documented fee; nothing stays with the router or goes to an address the caller did not choose.
5. Native value spent across all hops equals `msg.value` plus native received during the route.
6. A signed order fills at most its signed amount in total across partial fills, only before its deadline, only once per nonce, and only through the parties the signature names.
7. Adding a route, adapter, or facet never weakens the target and selector validation that existing routes enforce.
8. A callback entry point (`uniswapV3SwapCallback`, `unlockCallback`, flash-loan callbacks) pays only a pool that the router itself called in this transaction, and only the amount that pool's swap requires.

## Where value moves

- **Entry points:** `swap`, `multicall`, `execute(calls)`, `processRoute`, `fill`/`settleOrders`, facet functions behind a diamond's fallback, `permit`-plus-swap combos, bridge `startBridgeTokensVia*`.
- **Approvals at rest:** every contract users approve (router, approval proxy, Permit2). An unlimited approval to one of these is a standing claim on the user's wallet that the router's weakest path can spend.
- **Exit points:** swap outputs to `recipient`, refunds of unspent input and native dust, fee transfers, bridge deposits, `rescueFunds`/`sweep`.
- **Privileged parameters:** route, adapter, and facet registries (`addRoute`, `diamondCut`), target and selector allowlists, fee recipients and rates, solver/resolver allowlists, pause, executor addresses on destination chains.
- **External dependencies:** each DEX's callback contract, token behavior (catalog A1, B1, B4, C1, C6, D1, D3, E1, F1, F2 in `skill://smart-contract-audit/references/weird-erc20.md`), WETH, Permit2, bridges and their executors.

## Bug classes

### Caller-controlled call target and calldata
- **Mechanism:** the router calls `target.call(data)` with both chosen by the caller. With `target = token` and `data = transferFrom(victim, attacker, allowance)`, the router spends every approval it holds. Variants: the target comes from a registry entry added later without the validation older entries carry; the check runs on one field while a different field is executed; selector allowlists that allow `transferFrom` or `approve`; a "safe" adapter that forwards `data` to its own target. Dexible (2023): `selfSwap` accepted a `router` and `routerData` from the caller. Socket (2024): a route added three days earlier ran `fromToken.call(swapExtraData)`. LI.FI (2024): a new facet called LibSwap without the contract and function allowlist every other facet enforced.
- **Where to look:** every `.call(`, `functionCall(`, `delegatecall(`, and assembly `call` whose target or data traces to calldata; route and adapter registries and the date each entry was added; balance checks that guard the call.
- **Ask:** For every external call, can the caller set the target to a token or a contract users approved, and can they set the selector to one that moves someone else's funds?
- **Prove:** Foundry PoC: victim approves the router, attacker submits a route with `target = token` and `data = abi.encodeCall(IERC20.transferFrom, (victim, attacker, amount))`; assert the attacker's balance increases. Then assert invariant 1 for every route ID in the registry, not just the one under review.
- **Category:** walk `skill://smart-contract-audit/references/arbitrary-calls-approvals.md` in full.

### Balance-delta checks that measure the wrong thing
- **Mechanism:** routers replace target validation with "the router's balance of X did not drop" or "the output was at least `amount`". Socket's swapper compared a native-balance change against the caller-supplied `amount`, and the attacker passed 0, so a call that pulled victims' WETH passed the check. A check on the router's balance misses theft from users' wallets; a check on the input token misses theft of any other token.
- **Where to look:** `balanceBefore`/`balanceAfter` pairs, which account and which token they read, whether the threshold comes from calldata.
- **Ask:** Does the check bound the change in every wallet that has approved this contract, or only the router's own balance of one token?
- **Prove:** extend the PoC with `amount = 0` and with a token other than the one checked.

### Callback spoofing and route-decoded payers
- **Mechanism:** routers implement DEX callbacks and pay `amountDelta` from a `payer` decoded from callback data. If the callback authenticates `msg.sender` against a pool address that came from the caller's route rather than from the factory's deterministic address, an attacker deploys a fake pool, puts it in the route, and calls back as that pool with `payer = victim`. Sushi RouteProcessor2 (2023) stored the route-decoded pool as `lastCalledPool` and accepted callbacks from it.
- **Where to look:** `uniswapV3SwapCallback`, `pancakeV3SwapCallback`, `algebraSwapCallback`, flash-loan receivers, `unlockCallback`; how `payer` is chosen; how the expected caller is derived.
- **Ask:** Is the callback's expected caller computed from the factory and pool key (`computeAddress`) or read from attacker input, and is the payer pinned to the transaction's `msg.sender`?
- **Prove:** a fake pool contract whose `swap` immediately calls the router's callback with `payer = victim`; assert revert.

### Approvals the router grants to targets
- **Mechanism:** the router approves a DEX or bridge for `type(uint256).max` and leaves it set; a later malicious or compromised target spends the router's balance mid-route. Resetting with `approve(amount)` on a token with a nonzero residue reverts on catalog C1; `approve(0)` reverts on catalog C6; tokens without a return value (A1) revert on checked `IERC20.approve`.
- **Where to look:** `approve`, `safeApprove`, `forceApprove`, `safeIncreaseAllowance` calls, and the allowance left after the hop.
- **Ask:** After each hop, what allowance does the router still grant, and to whom?
- **Prove:** assert invariant 2 (`allowance(router, target) == 0`) after every successful route in a fuzz campaign over route shapes.

### Slippage enforced on the wrong token or account
- **Mechanism:** `minAmountOut` checked on an intermediate hop, on the router's balance instead of the recipient's, on the requested amount instead of the received amount (catalog B1 fee-on-transfer, B4 rebasing), or computed on-chain from the same pools. Positive slippage (output above the quote) captured by the router, or by whoever calls `sweep` next, is value taken from the user.
- **Where to look:** where `minAmountOut` is compared; whether the comparison reads `balanceOf(recipient)` before and after; surplus handling.
- **Ask:** Does the final check measure what the recipient actually gained in the final token?
- **Prove:** route through a fee-on-transfer mock as the last hop; assert the transaction reverts when the received amount is under the minimum.

### Native value across hops and multicall
- **Mechanism:** a loop or `multicall` (via `delegatecall` to self) where each sub-call reads `msg.value` spends the same ETH N times, draining ETH the router holds from other paths. Native-in routes that wrap partially leave dust; native-out routes that `call` a recipient hand control to the recipient mid-route; tokens that are also native (catalog F2) double-count.
- **Where to look:** `payable` functions reachable from `multicall`, `msg.value` reads inside loops, WETH `deposit`/`withdraw` amounts, refund of `address(this).balance` (which includes other users' ETH).
- **Ask:** Is `msg.value` consumed once with a running remainder, and does the refund return exactly the caller's unspent ETH?
- **Prove:** `multicall` with two sub-calls each spending `msg.value`; assert the second reverts or the router's ETH balance is unchanged.

### Refunds, dust, recipients, and fees
- **Mechanism:** unspent input left on the router after an exact-out route or a partial fill is lost to the next caller or to `sweep`. `recipient = address(0)` burns funds, and `recipient = router` traps them. Fees computed on the input before a fee-on-transfer haircut double-charge the user. `rescueFunds` callable by an admin with live user balances is a centralization risk; callable by anyone, it is theft.
- **Where to look:** exact-output paths, refund logic, `recipient` defaults, fee math, sweep and rescue functions.
- **Ask:** After any successful route, where is every leftover unit and who can move it?
- **Prove:** property for invariant 4: sum of user output, user refund, and fee equals input across a fuzzed route set.

### Signed orders, intents, and solver settlement
- **Mechanism:** a fill function that trusts solver-supplied amounts must bound them by the signed order; partial fills that track `filled` per order hash break when the hash omits a field the solver can vary; exclusivity windows checked against the wrong address let others fill first; a resolver-provided interaction or suffix parsed in assembly can be forged. 1inch Fusion v1 (2025): an underflow on `interactionLength` in the Yul `_settleOrder` let the attacker plant a fake resolver suffix and drain a resolver contract. A cancel that requires a transaction lets solvers front-run it; a fill that pushes ETH to the maker lets a maker contract revert to grief solvers.
- **Where to look:** order struct hashing (EIP-712 typehash versus struct fields), `remaining`/`filled` maps, deadline and nonce checks, assembly calldata parsing, resolver and solver authorization.
- **Ask:** Is every field the settlement reads covered by the signature or bounded by it, and does assembly parsing reject lengths larger than the calldata?
- **Prove:** fuzz the signed order and the solver's inputs; assert invariant 6. For assembly parsers, fuzz lengths at `0`, `calldatasize`, and `type(uint256).max`.

### Permit, Permit2, and signature-based pulls
- **Mechanism:** a router that calls `permit` and then `transferFrom` breaks when the permit was front-run (the allowance already exists, so the permit reverts), when the token has a fallback that accepts any `permit` without effect (catalog A6/C10: WETH9-style phantom permit), or when it follows DAI-style semantics (C9). Permit2 `permitTransferFrom` with a `witness` binds the swap parameters; without a witness, a captured signature can be used with different routes. Signature-transfer nonces are unordered bitmaps; allowance-transfer nonces are sequential.
- **Where to look:** `permit` calls not wrapped in try/catch with an allowance fallback, Permit2 witness type strings, which address is checked as the signature's owner.
- **Ask:** Can a third party replay, front-run, or substitute the parameters bound to a user's signature?
- **Prove:** front-run the permit in a test and assert the user's route still succeeds; submit the signature with altered route data and assert revert.

### Diamond and facet management
- **Mechanism:** aggregator diamonds add facets for each integration. Each facet repeats or skips the shared validation library, may write storage through its own struct at a colliding slot, and may add a selector that clashes with an existing one or with the fallback route. Socket reached route 406 by calling selector `0x00000196`, which fell through to a fallback that dispatched by selector value.
- **Where to look:** `diamondCut` history, each facet's use of the shared validation library, `LibStorage`-style slot constants, fallback dispatch logic.
- **Ask:** Does every facet that executes swaps enforce the same allowlist, and does every storage struct have a unique namespaced slot?
- **Prove:** enumerate facets and selectors from the deployed diamond (`facets()` loupe) and run the arbitrary-call PoC against each swap-capable facet.
- **Category:** walk `skill://smart-contract-audit/references/upgradeability.md` for storage and dispatch.

### Bridge legs and destination execution
- **Mechanism:** routers that bridge forward user calldata to a destination executor that holds approvals or funds; the same arbitrary-call class repeats on the destination chain with a different trust boundary. Failed destination calls must refund the user on the destination, not strand funds in the executor.
- **Where to look:** destination executors, `receiver` contracts, refund address handling, message replay protections.
- **Ask:** On the destination chain, who can call the executor and what can its calldata reach?
- **Prove:** see `skill://smart-contract-audit/references/playbooks/bridges-messaging.md`.

### Reentrancy through hop tokens and recipients
- **Mechanism:** a route hands control out at every hop: tokens with hooks (catalog E1, E3), native ETH sent to a `recipient`, and attacker-listed pools whose `swap` runs arbitrary code. A router that keeps per-transaction state in storage (a "current payer", an expected-callback pool, a running `msg.value` remainder) can have that state read or overwritten by a nested route entered from one of those hops. Transient slots (`tstore`) persist across every call in the transaction, so a payer or expected-pool slot the outer route writes and does not clear after use stays readable by every later call in the same transaction.
- **Where to look:** storage or transient slots written before external calls and cleared after; `nonReentrant` coverage on every external entry point, including callbacks and `multicall`.
- **Ask:** If a hop re-enters the router with a new route, which values from the outer route does the inner route read?
- **Prove:** a malicious pool whose `swap` re-enters `swap` with `payer` pointing at the outer user; assert revert.

### Batch routes that swallow failures
- **Mechanism:** `try/catch` or `(bool ok,) = target.call(...)` with `ok` ignored lets a failed hop pass silently; the route then continues with zero output from that hop, and the final check only catches it if it reads the recipient's balance. Partial-success batches that refund on failure must refund the failed leg's input, not a fixed amount.
- **Where to look:** ignored `success` returns, `try`/`catch` around hops, `allowFailure` flags in multicall variants.
- **Ask:** When a hop fails, where does its input go and does the route still report success?
- **Prove:** make one hop revert; assert either a full revert or exact refund of that leg's input to the user.

## Checklist items to walk

- External calls: `SOL-EC-1`, `SOL-EC-2`, `SOL-EC-3`, `SOL-EC-4`, `SOL-EC-5`, `SOL-EC-6`, `SOL-EC-7`, `SOL-EC-8`, `SOL-EC-9`, `SOL-EC-10`, `SOL-EC-11`, `SOL-EC-12`, `SOL-EC-13`, `SOL-EC-14`.
- Swaps and slippage: `SOL-Defi-AS-2`, `SOL-Defi-AS-3`, `SOL-Defi-AS-4`, `SOL-Defi-AS-6`, `SOL-Defi-AS-7`, `SOL-Defi-AS-14`, `SOL-AM-SandwichAttack-1`.
- Uniswap integration: `SOL-Integrations-Uniswap-1`, `SOL-Integrations-Uniswap-2`, `SOL-Integrations-Uniswap-6`, `SOL-Integrations-Uniswap-8`.
- Native value and loops: `SOL-Basics-AL-11`, `SOL-Basics-Payment-1`, `SOL-Basics-Payment-4`, `SOL-Heuristics-14`, `SOL-LL-1`, `SOL-LL-2`, `SOL-LL-3`.
- Signatures and replay: `SOL-Signature-1`, `SOL-Signature-2`, `SOL-Signature-3`, `SOL-Signature-4`, `SOL-Signature-5`, `SOL-AM-ReplayAttack-1`, `SOL-AM-ReplayAttack-2`, `SOL-AM-FrA-4`.
- Access and admin: `SOL-Basics-AC-1`, `SOL-Basics-AC-4`, `SOL-CR-2`, `SOL-CR-4`, `SOL-Basics-PU-6`, `SOL-Basics-PU-9`.
- Tokens: `SOL-Token-FE-2`, `SOL-Token-FE-6`, `SOL-Token-FE-7`, `SOL-Heuristics-3`; catalog `skill://smart-contract-audit/references/weird-erc20.md`.
- Cross-chain legs: `SOL-McCc-6`, `SOL-McCc-8`, `SOL-McCc-9`, `SOL-McCc-13`.
- Whole files: `skill://smart-contract-audit/references/arbitrary-calls-approvals.md`, `skill://smart-contract-audit/references/upgradeability.md`, `skill://smart-contract-audit/references/account-abstraction.md` (bundled and delegated execution of routes).

Proof shapes: `skill://test-foundry/references/exploit-poc.md`, `skill://fuzz-echidna-medusa/references/property-catalog.md`. Rate findings with `skill://smart-contract-audit/references/methodology/severity.md`; standing-approval theft reaches every approving wallet, so count those wallets and their allowances on-chain when sizing impact.

## Precedent

- **Opyn, 2020:** one `msg.value` reused across a loop of exercises; the native-value class above. https://medium.com/opyn/opyn-eth-put-exploit-post-mortem-1a009e3347a8
- **Transit Swap, 2022:** approvals granted to its cross-chain approve proxy were spent from hundreds of wallets. https://www.certik.com/blog/transit-swap-incident-report
- **Dexible, 2023:** `selfSwap` executed caller-chosen `router` and `routerData`; set to a token and `transferFrom(victim, attacker, ...)`. https://raw.githubusercontent.com/SunWeb3Sec/DeFiHackLabs/main/src/test/2023-02/Dexible_exp.sol
- **Sushi RouteProcessor2, 2023:** callback authenticated against a pool decoded from the caller's route; fake pool pulled approved users' funds, about $3.3M. https://blocksec.com/blog/8-sushi-swap-incident-a-clumsy-rescue-attempt-leads-to-a-series-of-copycat-attacks
- **Socket, 2024:** a newly added route ran `fromToken.call(swapExtraData)` behind a native-balance check the attacker zeroed; about $3.3M from 230 wallets. https://www.certik.com/blog/socket-tech-incident-analysis
- **LI.FI, 2024:** a new facet skipped the call allowlist other facets enforced; about $11.6M from 153 wallets with infinite approvals. https://li.fi/knowledge-hub/incident-report-16th-july
- **1inch Fusion v1, 2025:** Yul calldata-length underflow in settlement let the attacker forge a resolver suffix; a resolver lost about $5M. https://www.decurity.io/research/yul-calldata-corruption-1inch-postmortem
