# Arbitrary Calls & Approvals

Profile-authored category (not part of the vendored Cyfrin checklist).

Total items: 22

Token-specific behavior (USDT approve, phantom permit, hooks, double entry points) is catalogued by stable ID in `skill://smart-contract-audit/references/weird-erc20.md`. Items below cite those IDs rather than restate them.

## Arbitrary calls from contracts that hold approvals

### AUD-Call-1: Can any caller-supplied `(target, data)` pair execute from a contract that users have approved (ERC-20 `approve`, Permit2 allowance, `setApprovalForAll`)?
- **Risk:** The executing contract is `msg.sender` to the token. With `target = token` and `data = transferFrom(victim, attacker, balance)`, every wallet that granted the contract an approval is drained in one transaction. This works on any path that reaches the call: a swap-data executor, a "generic" bridge adapter, a multicall, a hook. Precedents: LI.FI `GasZipFacet` on 2024-07-16 (~$11.6M from 153 wallets holding infinite approvals) and Socket/Bungee route 406 on 2024-01-16 (~$3.3M from 230 wallets). SOL-Defi-AS-6 and SOL-EC-5 ask whether arbitrary calls exist at all; this item asks what the caller inherits.
- **Fix:** Split custody from execution. The approved contract only pulls `from == msg.sender` (or a verified signer) into a separate executor that holds no approvals, and the executor performs the untrusted call. Otherwise, block every token address as a call target.
- **Refs:** 2 case(s)
  - https://li.fi/knowledge-hub/incident-report-16th-july
  - https://www.certik.com/blog/socket-tech-incident-analysis

### AUD-Call-2: Does call validation check the `(target, selector)` pair, and does it reject approval-moving selectors on every target?
- **Risk:** Each common validation shape has a bypass. A target allow-list alone fails when an allowed DEX router or aggregator exposes a function that takes a `from` or `payer` argument, or one that spends approvals users granted to that router. A selector allow-list alone fails when `target` is a token. A denylist of `transferFrom` misses `transfer`, `approve`, `increaseAllowance`, `permit`, `setApprovalForAll`, `safeTransferFrom`, and Permit2 `transferFrom`/`permitTransferFrom`. It also misses tokens whose fallback calls arbitrary targets as the token (E2) and tokens with a second entry address (F1).
- **Fix:** Allow-list exact `(target, selector)` pairs that governance has audited. Decode the arguments of each allowed selector and force `from`/`payer`/`recipient` fields to `msg.sender` or the contract itself.

### AUD-Call-3: Is any post-call balance check a complete proof of correctness, or can it pass while the call moved someone else's funds?
- **Risk:** Socket's route enforced "contract balance increased by `amount`". The attacker passed `amount = 0` and calldata that ran `transferFrom(victim, attacker, x)`, so the check passed trivially. Before/after checks on the executor's own balance cannot see transfers between third parties, and rounding tolerances let small leaks pass in a loop.
- **Fix:** Use balance checks as accounting, not as authorization. Pair them with AUD-Call-1/2 restrictions, and reject `amount == 0` on paths that execute calldata.
- **Refs:** 1 case(s)
  - https://www.certik.com/blog/socket-tech-incident-analysis

### AUD-Call-4: Does the validator decode the calldata with the same ABI decoding that execution uses?
- **Risk:** Hand-rolled checks such as `bytes4(data[:4])`, fixed-offset reads (`data[4:36]` as recipient), or `abi.decode` of a different struct than the target uses are bypassed with non-canonical encodings. Dynamic-type offsets can point anywhere, so the validated word is not the decoded word. Trailing bytes and duplicate heads are ignored by the target. Upper bits of an address word can be dirty. Session-key validators, intent settlers, and Safe guards that inspect `MultiSend` payloads are the usual sites.
- **Fix:** Decode with `abi.decode` into the target's exact parameter types, validate the decoded values, and re-encode with `abi.encodeCall` for execution so the bytes executed are the bytes validated.

### AUD-Call-5: Is adding a facet, route, adapter, or module to an approval-holding contract time-locked, and does each addition pass the same call validation as existing paths?
- **Risk:** Both LI.FI and Socket were drained through a code path added days before the exploit (a new diamond facet, a new route via `addRoute`) that skipped the validation older paths ran. Users had approved the router address, not a code version. Every addition silently extends the trust grant behind those approvals.
- **Fix:** Route all user-supplied calldata through one shared validation library and test that every registered selector or route calls it. Add a timelock to `diamondCut`/`addRoute`/`setAdapter`, plus an emergency disable. Default the UI to exact-amount approvals: LI.FI states finite approvals were not affected.
- **Refs:** 2 case(s)
  - https://li.fi/knowledge-hub/incident-report-16th-july
  - https://www.certik.com/blog/socket-tech-incident-analysis

### AUD-Call-6: Does every function that moves tokens with `transferFrom(from, …)` or Permit2 `transferFrom(from, …)` use `from == msg.sender`, or a `from` whose signature was verified in the same call?
- **Risk:** A `from` parameter in a deposit, swap, or repay helper ("pay on behalf", "zap for") lets anyone pull from every address that approved the contract, crediting the attacker or a recipient the attacker chooses. SOL-Token-NfE1-4 covers NFTs; this is the fungible and Permit2 equivalent.
- **Fix:** Pull from `msg.sender`. For delegated pulls, require an EIP-712 signature by `from` that binds recipient, amount, nonce, and deadline.

### AUD-Call-7: Does the executor hold privileges other than token approvals, such as being owner, minter, or guardian of other contracts, holding an operator role in a lending market, holding Permit2 allowances, or being trusted as `msg.sender` by a sibling contract?
- **Risk:** An arbitrary call acts with every right the executor has anywhere: it can mint from a token the executor administers, call `setOperator`/`borrowOnBehalf` in a market that whitelists it, or call a sibling contract's `onlyRouter` function. That gives privilege escalation from a single `call(target, data)`.
- **Fix:** Grant no roles to the address that executes untrusted calldata. List every external role the executor holds and block those contracts as targets.

### AUD-Call-8: Before calling a user-chosen spender or target, does the contract approve the exact amount and reset the allowance to zero afterwards?
- **Risk:** The "approve then call" pattern (`token.approve(swapTarget, amountIn); swapTarget.call(data)`) leaves residual allowance when the target pulls less than approved, or nothing at all. The user-chosen spender later pulls that allowance plus any tokens that arrive in the contract. `type(uint256).max` approvals to whitelisted routers turn any router bug into a loss of the contract's balance. Resetting is token-sensitive: USDT-style tokens cannot overwrite non-zero allowances (C1) and BNB-style tokens revert on `approve(0)` (C6).
- **Fix:** Approve exactly `amountIn`, call, then reset to zero using a `forceApprove`-style helper that tolerates C1/C6 tokens. Assert allowance is zero after the call in tests.

## Native ETH and residual balances

### AUD-Call-9: Is the `value` forwarded with a caller-supplied call bounded by the `msg.value` of this transaction, rather than drawn from the contract's balance?
- **Risk:** Routers and executors take a per-call `value` field and run `target.call{value: v}(data)`. If the sum of `v` is not checked against `msg.value` (minus amounts already used), the caller spends ETH the contract holds for other users: queued refunds, wrapped-ETH in transit, fee balances. With delegatecall-based `multicall`/`batch`, every sub-call sees the same `msg.value`. samczsun's MISO disclosure (2021) shows `BoringBatchable` reusing one payment across many `commitEth` calls, with refunds turning it into a drain. SOL-EC-2 flags multicall ETH generally.
- **Fix:** Track ETH spent in a local accumulator and require `spent <= msg.value`. In batched delegatecall, make payable sub-functions read an internal remaining-value counter, not `msg.value`.
- **Refs:** 1 case(s)
  - https://www.paradigm.xyz/2021/08/two-rights-might-make-a-wrong

### AUD-Call-10: After each user operation, does the contract return its entire balance delta (input leftovers, positive slippage, partial-fill remainders, target refunds) to that user?
- **Risk:** Routers often send the user only the minimum or the quoted amount. Anything extra stays in the contract and becomes free money for the next caller: a public `sweep(token, to)` or `refundETH()`, a later swap that uses `balanceOf(this)` as its input amount, or an arbitrary call. Targets that refund ETH to `msg.sender` refund the router, not the user. SOL-Integrations-Uniswap-2 asks whether refunds exist; this item asks who can claim what is left.
- **Fix:** Snapshot balances before and after each operation and forward the delta to the user in the same call. Restrict `sweep` to governance, sending to a fixed treasury. Use explicit `amountIn`, never `balanceOf(this)`.

### AUD-Call-11: Are refunds and outputs sent to the user named in the signed order or recorded deposit, rather than `msg.sender`, when relayers, forwarders, solvers, or routers can be the caller?
- **Risk:** In meta-transaction, intent, and aggregator flows `msg.sender` is the relayer or router. Refunding it gifts the user's funds to a third party, or bricks the operation when that caller is a contract with no `receive()`. The reverse also applies: pushing ETH to a user-supplied recipient that reverts blocks the whole batch.
- **Fix:** Use the signer or recorded owner as the refund recipient. Wrap ETH sends to untrusted recipients so a refusing recipient records a pull-claim instead of reverting the batch.

## Permit, Permit2, and signature approvals

### AUD-Call-12: When a `permit` call reverts, does the contract continue if the allowance it needs is already in place?
- **Risk:** Permit signatures are public once in the mempool. Anyone can submit the same `permit` first, which consumes the nonce and grants the allowance. The victim's `permitAndDeposit` then reverts on the used nonce. The attacker gains nothing, but can grief every permit-based entry point at near-zero cost.
- **Fix:** `try token.permit(...) {} catch {}` followed by `require(token.allowance(owner, address(this)) >= amount)`, as in Trust Security's trustlessPermit.
- **Refs:** 2 case(s)
  - https://github.com/trust1995/trustlessPermit
  - https://github.com/code-423n4/2024-07-loopfi-findings/issues/73

### AUD-Call-13: Does a permit-then-`transferFrom` path pull only from the address that signed, and does it still hold when `permit` is a silent no-op?
- **Risk:** Tokens with a non-reverting fallback (WETH9) accept any `permit(...)` call and do nothing (A6/C10). A function shaped `permit(from, …); transferFrom(from, …)` with caller-supplied `from` and signature then pulls from anyone who already approved the contract, with a garbage signature. This combines the try/catch fix of AUD-Call-12 with the `from` check of AUD-Call-6, and the combination needs its own test.
- **Fix:** Require `from == msg.sender`, or verify the signature independently of the token (EIP-712 over the protocol's own struct). Test against a WETH9-style token from a pre-state with a pre-existing allowance and an invalid signature.

### AUD-Call-14: Does a Permit2 SignatureTransfer integration pass `msg.sender` (or a verified order signer) as `owner`, and does the witness bind every parameter that determines where the value goes?
- **Risk:** In `permitTransferFrom` the caller supplies `owner`, and only the signature ties that owner to the transfer. A router that forwards "any valid permit" lets a front-runner submit the victim's signed permit with themselves as recipient; the Uniswap docs warn about exactly this. Without a witness, the signature authorizes the transfer but not the action, so recipient, `minAmountOut`, target chain, and order id are attacker-chosen. Witness integrations also fail when `witnessTypeString` is not the exact EIP-712 type tail, with `TokenPermissions` in sorted position among the referenced struct types.
- **Fix:** Pass `owner = msg.sender`, or recover the order signer from the witness. Put recipient, amounts, deadline, and destination into the witness struct. Golden-test the witness type hash against an off-chain EIP-712 encoder.
- **Refs:** 1 case(s)
  - https://developers.uniswap.org/docs/protocols/permit2/concepts/signature-transfer

### AUD-Call-15: Does a Permit2 AllowanceTransfer integration handle `uint160` amounts, `uint48` expirations, and per-spender nonces correctly?
- **Risk:** `amount` is `uint160`. An unchecked `uint160(x)` cast of a `uint256` user amount truncates: a huge request moves a small amount while accounting credits the full value. `type(uint160).max` means unlimited, not "a large number". `expiration = 0` means the allowance expires at the current `block.timestamp`, so it is usable only in that block. Integrations that store a zero expiration expecting "no expiry" fail one block later. Allowances and nonces are keyed `(owner, token, spender)`.
- **Fix:** Use `SafeCast.toUint160`. Set an explicit future expiration. Read `allowance(owner, token, address(this))` before relying on it, and apply the AUD-Call-12 try/catch pattern to Permit2 `permit` as well.
- **Refs:** 1 case(s)
  - https://developers.uniswap.org/docs/protocols/permit2/concepts/allowance-transfer

### AUD-Call-16: Is the code behind every address that receives standing user approvals or Permit2 allowances fixed, or else changeable only through a timelock users can exit before?
- **Risk:** An approval to a proxy, a diamond, or a contract with a mutable route/adapter registry is an approval to whatever code that address runs in future. A compromised upgrade key, or a single buggy addition (AUD-Call-5), reaches every historical approval at once. Users cannot react because standing approvals are never revisited.
- **Fix:** Use an immutable spender, such as an approval-holding pull contract with a fixed interface, and keep the upgradeable logic behind it. Otherwise put a timelock longer than the user exit window on upgrades. See `skill://smart-contract-audit/references/upgradeability.md` for upgrade-path checks.

## Callbacks and hooks

### AUD-Call-17: Do flash-loan receivers check that they initiated the loan (`initiator == address(this)` and `msg.sender == lender`), including on lenders whose callback has no initiator argument?
- **Risk:** ERC-3156 `flashLoan(receiver, …)` lets anyone name any receiver. The lender passes its own caller as `initiator`, and the reference borrower checks both `msg.sender == lender` and `initiator == address(this)`. A receiver that checks only the lender can be made to borrow by anyone. It then pays the fee from its own balance (it must approve `amount + fee`) and executes the attacker's `data`: liquidations, swaps, or unwinds using its approvals and positions. Balancer V2 `Vault.flashLoan(recipient, …)` also accepts any recipient, and `receiveFlashLoan(tokens, amounts, feeAmounts, userData)` carries no initiator, so the receiver must set and check its own transient flag. SOL-Defi-AS-12 covers only the caller-address half.
- **Fix:** Check both fields, or set a transient "loan in progress" flag in the function that requests the loan and require it in the callback. Decode `data` only after both checks pass.
- **Refs:** 2 case(s)
  - https://eips.ethereum.org/EIPS/eip-3156
  - https://raw.githubusercontent.com/balancer/balancer-v2-monorepo/master/pkg/interfaces/contracts/vault/IFlashLoanRecipient.sol

### AUD-Call-18: Does an `onERC721Received`/`onERC1155Received`/`tokensReceived` handler that credits a deposit verify that `msg.sender` is an accepted collection, and that the asset actually arrived?
- **Risk:** Anyone can call the receiver hook directly, or from a fake collection, with arbitrary `operator`, `from`, `tokenId`, and `data`. A contract that credits `from` for `tokenId` on hook entry mints shares, stake, or a loan against an NFT it never received. Treating `data` as instructions without checking `operator` lets a third party trigger actions on behalf of `from`. SOL-Token-NfE1-2/3 cover reentrancy through these hooks, not forged invocation.
- **Fix:** Require `msg.sender` to be in the collection allow-list and `IERC721(msg.sender).ownerOf(tokenId) == address(this)` (or a balance delta for 1155) before crediting. Bind `data` actions to `operator == from`.

### AUD-Call-19: Does any authorization treat `msg.sender == token` as proof of a token-originated callback when the token can forward arbitrary calls?
- **Risk:** Some tokens let holders make the token contract itself call any target with chosen data (ATN-style custom fallback, catalog E2). Hook-based designs that authorize calls by `msg.sender == token` can then be invoked by any holder with forged amounts. Examples are ERC-777 `tokensReceived` (E1), ERC-1363/677 `transferAndCall` receivers (E3), and accounting that trusts `msg.sender == stakingToken`. When the token is also an approved spender somewhere, the forwarded call spends those approvals.
- **Fix:** Authorize hook entry by measuring the balance delta, not by trusting the hook's parameters. For each listed token, check whether the token can make calls of its own (E2), and exclude such tokens or isolate them in a contract that holds no approvals.

## Return data from untrusted calls

### AUD-Call-20: Is return data from untrusted targets decoded so that a malformed response cannot revert the caller outside its error handling?
- **Risk:** `try target.f() returns (uint256 x)` catches reverts inside `target`, but ABI-decoding the return data happens in the caller, so short, empty, or out-of-range return data reverts past the `catch`. The same holds for `abi.decode(ret, (bool))` after a low-level call when `ret` is not 32 bytes. One hostile token, oracle, or hook in a loop (liquidation sweeps, batch claims, reward distribution) then bricks the whole operation. SOL-Basics-VI-OVI-12/13 are instances of this pattern in older OpenZeppelin versions.
- **Fix:** Make a low-level call, check `ret.length` (and value range for `bool`/`address`) before decoding, and treat malformed data as failure. Return-bomb and gas-stipend concerns are in `skill://smart-contract-audit/references/evm-compiler.md`.

### AUD-Call-21: Does the contract treat values returned by caller-chosen contracts (tokens, vaults, pools, "oracles") as claims rather than facts?
- **Risk:** If a user supplies the `token`, `vault`, or `pool` address, every return value is attacker-authored: `transferFrom` returns `true` without moving anything, `balanceOf` reports any balance, `convertToAssets` or `getReserves` returns any price, `decimals` returns 255. Protocols that credit deposits from `transferFrom`'s return value or from the asset's self-reported `balanceOf` mint against nothing. SOL-EC-12 covers code-less targets returning success.
- **Fix:** Accept only allow-listed asset and pool addresses, or derive them from a trusted factory (CREATE2-computed pool address). Credit from a balance delta measured on a trusted token.

### AUD-Call-22: When the contract bubbles up revert data or records failures from arbitrary calls, does the error path keep the attacker from choosing the outcome?
- **Risk:** Executors that run `(bool ok, bytes memory ret) = target.call(data)` and then, on `!ok`, continue, mark the step failed, or consume a nonce let the caller pick which inner calls fail by forwarding too little gas (63/64 rule) or a target that reverts on demand. A relayer can then fail a signed meta-transaction while burning the user's nonce or fee. Re-throwing `ret` verbatim lets the target forge error selectors that the caller's own `catch` clauses match (for example faking an `InsufficientLiquidity` error that triggers a fallback route).
- **Fix:** Require `gasleft()` above the signed or declared gas before the call, and revert the whole operation when a mandatory step fails. Match custom errors only from trusted callees. Wrap untrusted revert data in a protocol error instead of re-throwing it raw.
