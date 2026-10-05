# Account Abstraction & Smart Accounts

Profile-authored category (not part of the vendored Cyfrin checklist).

Total items: 24

## ERC-4337 accounts

### AUD-AA-1: Do `validateUserOp`, `execute`/`executeBatch`, and `executeUserOp` accept calls only from the pinned EntryPoint (plus the account itself or owner where intended)?
- **Risk:** `validateUserOp` verifies the signature against the `userOpHash` *argument* and then pays `missingAccountFunds` to `msg.sender`. If any caller is accepted, an attacker replays an old validly signed `(userOp, userOpHash)` pair with `missingAccountFunds` set to the account's balance and receives the ETH. Ungated `execute*` is direct arbitrary-call takeover. An EntryPoint address that is mutable (owner setter, initializer argument, or old version still trusted after migration) widens the trusted caller set to whatever that address runs.
- **Fix:** Require `msg.sender == entryPoint()` (immutable) in `validateUserOp`; allow `execute*` only from the EntryPoint, `address(this)`, or the owner; when migrating EntryPoint versions, revoke the old one in the same upgrade.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-4337

### AUD-AA-2: On a signature mismatch, does `validateUserOp` return `SIG_VALIDATION_FAILED` (1) after running the full validation path, including the `missingAccountFunds` payment, and revert only on other errors?
- **Risk:** The spec says accounts SHOULD return 1 rather than revert, and SHOULD complete the normal flow so bundlers can estimate gas with a dummy signature. An account that reverts, or returns early, on a bad signature breaks gas estimation: the `verificationGasLimit` it gets is too low, and real ops run out of gas (AA2x). The opposite bug is worse: it returns 0 on paths the author did not consider, such as an empty signature, `ecrecover` returning `address(0)` while `owner` is still unset, or a validator module that is not installed. Then anyone validates. Any non-zero value in the low 160 bits other than 1 is read as an aggregator address.
- **Fix:** Compute the result, pay the prefund, then return `sigFailed ? 1 : 0` packed with the time range. Reject `address(0)` signers and uninitialized owners explicitly. Simulate `handleOps` with an invalid dummy signature and assert validation returns 1 and consumes the same gas as a valid signature.
- **Refs:** 2 case(s)
  - https://eips.ethereum.org/EIPS/eip-4337
  - https://raw.githubusercontent.com/eth-infinitism/account-abstraction/develop/contracts/core/Helpers.sol

### AUD-AA-3: Is `validationData` packed as `authorizer | uint256(validUntil) << 160 | uint256(validAfter) << 208`, with `validUntil == 0` treated as "never expires"?
- **Risk:** Swapped `validUntil`/`validAfter`, values truncated to `uint48`, or a session key whose expiry defaults to 0 all produce ops that never expire. Mixing a block-number range (high bit set) with a timestamp range is invalid. `TIMESTAMP` and `NUMBER` are banned during validation (ERC-7562 OP-011), so a `block.timestamp` check written inside validation does not enforce expiry: bundlers drop the op instead. Time limits must travel through these return fields.
- **Fix:** Build the return value with the reference `_packValidationData` helper. Store explicit non-zero expiries for every scoped signer. Unit-test the packed word against `_parseValidationData` for expiry 0, max, and a past timestamp.
- **Refs:** 2 case(s)
  - https://raw.githubusercontent.com/eth-infinitism/account-abstraction/develop/contracts/core/Helpers.sol
  - https://eips.ethereum.org/EIPS/eip-7562

### AUD-AA-4: Does validation code (account, factory, paymaster, validator modules) follow ERC-7562 opcode and storage rules for its staking status?
- **Risk:** Canonical-mempool bundlers drop ops whose validation does any of the following: uses banned opcodes (`ORIGIN`, `TIMESTAMP`, `NUMBER`, `BASEFEE`, `BLOCKHASH`, `GASPRICE`, `CREATE` outside the deployment frame, `SELFDESTRUCT`); calls `BALANCE`/`SELFBALANCE` from an unstaked entity; reads storage of a non-entity contract that is not associated with the sender (an oracle price, a global module registry, a token's `totalSupply`); makes a value-bearing `CALL` to anything but the EntryPoint; touches addresses that have no code. Such an account, or the recovery/guardian flow behind it, only works through private bundlers. For a wallet whose only exit is a UserOperation, that is a liveness failure.
- **Fix:** Key validation-time reads on the sender (`keccak(sender || x) + n` slots), stake factories and paymasters that need their own storage, and move other reads into execution. Prove it by running the op through a bundler simulation that enforces ERC-7562 tracing.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-7562

### AUD-AA-5: Is any logic that depends on 2D nonces (192-bit key, 64-bit sequence) correct without assuming ordering across keys, and is every key-derived route authenticated?
- **Risk:** Sequences are ordered only within a key. A "revoke session key" or "rotate owner" op on key A does not invalidate an already-signed op on key B: the bundler can include B before A. Some accounts derive the validator or module from the nonce key or a signature prefix. If such an account skips checking that the selected validator is installed and allowed to authorize the target selector, the submitter picks the weakest validator.
- **Fix:** Bind privileged selectors to a dedicated key, following the spec's `ADMIN_KEY` pattern. Make revocation take effect through state read during validation, not through nonce ordering. Check the installed-validator registry and the per-validator selector scope on every key-routed validation.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-4337

### AUD-AA-6: Is every signature the account accepts outside `userOpHash` bound to `block.chainid`, `address(this)`, and (for ops) the EntryPoint?
- **Risk:** `userOpHash` already covers the EntryPoint and the chainId. Accounts usually have other authorization paths, though: owner-signed `executeWithSig`, guardian recovery, owner rotation, module install, or a "chain-agnostic" multichain signature. Accounts are deployed at the same CREATE2 address on many chains and move across EntryPoint versions, so any of those signatures that omits these fields replays on every chain and every EntryPoint where the account exists. This is a smart-account-specific case of SOL-Signature-1.
- **Fix:** Include chainId, the account address, and the EntryPoint in every custom digest. Restrict intentionally chain-agnostic signatures to idempotent config changes with their own replay nonce.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-4337

### AUD-AA-7: Does the factory derive the counterfactual address from every ownership-defining init parameter, return the existing account instead of reverting, and accept `createAccount` only from `entryPoint.senderCreator()`?
- **Risk:** If the CREATE2 salt or init code omits the owner, modules, or recovery config, an attacker deploys the victim's predicted address with their own owner before the first UserOperation, then sweeps funds that were sent to it counterfactually (address squatting; see SOL-AM-FrA-1). A factory that reverts when the account already exists breaks `getSenderAddress` and first-op flows. When `sender` already exists, `initCode` is silently ignored, so a first op that relies on `initCode` to install a module skips that step. The current spec requires factories to check that the caller is `senderCreator`.
- **Fix:** Salt = hash of all init parameters. Return the existing address. Gate `createAccount` to `senderCreator()`. Never do post-deploy configuration in `initCode` alone.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-4337

### AUD-AA-8: Are transient-storage (EIP-1153) values used for authorization, locks, or cached accounting cleared before each UserOperation ends?
- **Risk:** One bundle is one transaction that carries ops from unrelated senders. Transient storage persists across them. An "authorized caller" flag, a reentrancy lock left set, or a cached price written during op 1 is visible to op 2 in the same bundle, which gives either authorization bleed or a DoS of later ops. The same applies to shared modules and paymasters.
- **Fix:** Clear sensitive transient slots explicitly at the end of execution (and of `postOp`). Test two ops from different senders in one `handleOps` call.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-4337

## Paymasters

### AUD-AA-9: Does a verifying paymaster's signed digest commit to `sender`, `nonce`, every gas and fee field, `chainId`, the paymaster's own address, and a validity window? Are `validatePaymasterUserOp`/`postOp` callable only by the EntryPoint?
- **Risk:** The paymaster pays up to `maxCost` from its EntryPoint deposit. If its digest omits `callGasLimit`, `verificationGasLimit`, `preVerificationGas`, `maxFeePerGas`, or the paymaster gas limits, a sponsored user reuses the approval with inflated gas and drains the deposit to a colluding bundler `beneficiary`. Omitting `sender` or `nonce` lets anyone reuse one sponsorship. Omitting chainId or the paymaster address replays it on other chains or other paymaster instances that share the signer. With no `validUntil`, a sponsorship never expires. Under the `paymasterSignature` extension the paymaster's signature lies outside `userOpHash`, so the paymaster must hash these fields itself. Ops that pass validation and revert in execution still cost the paymaster gas; without a per-sender budget, they drain it.
- **Fix:** Hash the full packed op minus signatures, plus chainId and `address(this)`. Return `validUntil`/`validAfter`. Enforce per-sender spend caps in paymaster-associated storage. Gate both entry points to the EntryPoint.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-4337

### AUD-AA-10: Does an ERC-20 paymaster collect the maximum token cost during validation and refund in `postOp`, rather than pulling tokens only in `postOp`?
- **Risk:** In EntryPoint v0.7, a `postOp` revert rolls back the op's execution, `postOp` is not retried, and the paymaster's deposit is still charged `actualGasCost`. A user whose execution spends the tokens or revokes the allowance makes the `postOp` `transferFrom` revert. The user pays nothing and repeats the trick to drain the deposit. An exchange rate read in `postOp` from an AMM or oracle that the execution can move is a second lever.
- **Fix:** Pre-charge in validation (the sender's token balance and allowance are sender-associated storage, which STO-021 permits), fix the price into `context`, and refund the excess in `postOp`. Test with an op whose `callData` revokes the paymaster's allowance.
- **Refs:** 2 case(s)
  - https://raw.githubusercontent.com/eth-infinitism/account-abstraction/releases/v0.7/contracts/core/EntryPoint.sol
  - https://eips.ethereum.org/EIPS/eip-4337

### AUD-AA-11: Does `postOp` compute charges only from `context`, `actualGasCost`, and `actualUserOpFeePerGas`, never from state the UserOperation's execution can change?
- **Risk:** `postOp` runs after the user's own execution. Reading the user's balance, a spot price, paymaster config the user can call, or re-decoding fields not committed in `context` lets the user steer their own charge. A `context` larger than `MAX_CONTEXT_SIZE` (2048 bytes) makes bundlers drop the op.
- **Fix:** Commit every pricing input into `context` during validation. Treat `postOp` as pure arithmetic over `context` and the gas arguments.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-7562

## Session keys and scoped signers

### AUD-AA-12: Are session-key and scoped-signer permissions enforced on the effective call, meaning every batch entry, the target, selector, value, call type, and the gas/fee fields, rather than on the outer calldata shape?
- **Risk:** A validator that checks only the outer `execute(target, value, data)` selector misses several bypasses: a nested `executeBatch` or multicall; `target == address(this)` reaching `installModule`, `transferOwnership`, or `upgradeToAndCall`; a delegatecall execution mode; non-zero `value`. Calldata decoded at fixed offsets diverges from what the executor decodes (AUD-Call-4 in `skill://smart-contract-audit/references/arbitrary-calls-approvals.md`). Gas fields carry no permission, so a key holder can set a high `maxFeePerGas` and large gas limits that the account prefunds, which moves ETH to a colluding beneficiary.
- **Fix:** Decode exactly what execution will run and check each inner call. Deny self-targets and delegatecall for scoped keys. Cap value, `maxFeePerGas`, and total gas per key. Return expiry through `validUntil` (AUD-AA-3).

## ERC-1271 contract signatures

### AUD-AA-13: Does the account's `isValidSignature` bind the incoming hash to its own address and chainId (ERC-7739 nested EIP-712 or an equivalent defensive rehash)?
- **Risk:** When one key owns several smart accounts and the application's digest omits the account address (Permit2 signature transfers, CoW Swap's ERC-1271 path), a signature produced for account A validates for accounts B…N. A counterparty can then replay a payment across every account the owner holds. Alchemy disclosed this on 2023-10-27 for LightAccount, Kernel, Biconomy, and others; Safe was not affected.
- **Fix:** Rehash with the account's EIP-712 domain before verifying, using ERC-7739 `TypedDataSign`/`PersonalSign` so the wallet UI stays readable. Test that one owner signature verifies on exactly one of two accounts that share the owner.
- **Refs:** 2 case(s)
  - https://www.alchemy.com/blog/erc-1271-signature-replay-vulnerability
  - https://eips.ethereum.org/EIPS/eip-7739

### AUD-AA-14: Do signature consumers handle ERC-1271 signers as stateful, non-unique, and possibly reverting?
- **Risk:** An `ecrecover`-only verifier locks smart-account users out, so funds claimable only by signature get stuck. 1271 validity changes when owners rotate, so a signature pre-validated off-chain or a cached "verified" flag goes stale in both directions. Replay protection keyed on signature bytes or the signature hash fails, because one account can produce many valid encodings for one message and some accounts accept an empty signature for an on-chain pre-approved hash. A consumer that branches on `signer.code.length` routes EIP-7702 delegated EOAs to `isValidSignature`, while the EOA key itself remains a valid ECDSA signer whatever the delegate decides. Result checks must compare the exact magic `0x1626ba7e` and survive reverts and short return data (see SOL-Basics-VI-OVI-12).
- **Fix:** Put a nonce in the signed message and consume it. Accept both ECDSA and ERC-1271 signers, decide explicitly which path a delegated EOA takes, and re-verify 1271 signatures at use time instead of caching the result.

## EIP-7702 delegated EOAs

Opcode-level EOA detection (`code.length`, `EXTCODESIZE` returning 23 for `0xef0100 || address`, `tx.origin == msg.sender`) lives in `skill://smart-contract-audit/references/evm-compiler.md`. The items below cover delegate and protocol logic.

### AUD-AA-15: Can the delegate's initialization run only with parameters signed by the EOA key, or only from `entryPoint.senderCreator()`, and only once?
- **Risk:** A 7702 delegation sets code without running initcode, so initialization is a separate call. An observer front-runs `initialize(owner = attacker, …)` and takes over the EOA. The risk peaks when an existing smart-account implementation with an unprotected initializer is reused as a delegate. The EntryPoint cannot tell whether a 7702 account is initialized, so `initCode` can reach the init function repeatedly.
- **Fix:** Use an `initWithSig` that checks `ecrecover(digest) == address(this)` over all init parameters, chainId, and the delegate address, or gate init to `senderCreator()`. Use a one-shot flag in namespaced storage.
- **Refs:** 3 case(s)
  - https://eips.ethereum.org/EIPS/eip-7702
  - https://ethereum.org/roadmap/pectra/7702/
  - https://eips.ethereum.org/EIPS/eip-4337

### AUD-AA-16: Does the delegate root its storage in a unique ERC-7201 namespace and behave correctly when slots written by a previous delegate are present?
- **Risk:** Re-delegating does not clear storage. A new delegate that reuses slot 0..n reads leftovers: an `initialized = true` written by the old delegate blocks init (DoS), an old owner or module list is honored (takeover), or a `bool` is reinterpreted as a `uint`. Smart-account proxies that switch implementations face the same collision (`skill://smart-contract-audit/references/upgradeability.md`).
- **Fix:** Give each implementation and version its own ERC-7201 namespace. Use versioned initializers. For untrusted history, migrate through a purpose-built storage-clearing delegate.
- **Refs:** 2 case(s)
  - https://eips.ethereum.org/EIPS/eip-7702
  - https://ethereum.org/roadmap/pectra/7702/

### AUD-AA-17: Does every authorization the delegate verifies (relayed calls, sponsored execution) commit to a nonce, chainId, `address(this)`, target, calldata, value, and gas?
- **Risk:** Each omitted field opens a separate attack. Without a nonce the call replays. Without value a sponsor attaches unexpected ETH. Without gas a sponsor forwards too little gas, so the inner call fails while the nonce is consumed (or a try/catch swallows the failure). Without target and calldata anyone holding the signature performs an arbitrary call as the EOA. A weak delegate hands near-total control of the EOA to whoever submits.
- **Fix:** EIP-712 digest over all seven fields. Require `gasleft()` ≥ the signed gas before the inner call. Revert the whole relay on inner failure, or record the failure without consuming the nonce.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-7702

### AUD-AA-18: Are 7702 authorizations scoped to one chain, or, when `chain_id = 0`, do they point only at an immutable delegate deployed with identical code at the same address on every chain?
- **Risk:** A `chain_id = 0` tuple is valid on every EVM chain where the EOA's nonce matches. It may point at an address whose code differs elsewhere: a non-deterministic deployment, an upgradeable proxy, or a metamorphic contract. Then the user has delegated full control on those chains to whatever lives there. Wallet backends and protocols that request 0-chain authorizations, or delegate to proxies, carry this risk.
- **Fix:** Sign the specific chainId. If you need universal delegation, use only an immutable delegate deployed by CREATE2 with standard initcode.
- **Refs:** 1 case(s)
  - https://ethereum.org/roadmap/pectra/7702/

### AUD-AA-19: Does the account (7702 delegate or smart account) grant `msg.sender == address(this)` full authority only to calls that its highest-authority path originated?
- **Risk:** In a 7702 account, a transaction from the EOA to itself has `msg.sender == address(this) == tx.origin`, so delegates often gate admin functions with `onlySelf`. The generic `execute`/batch path is also reachable by session keys, signed relays, modules, and restricted ERC-4337 validators. If that path allows `target == address(this)`, restricted authority escalates to self-authority: adding an owner, swapping the validator, upgrading a proxy pointer.
- **Fix:** Reject self-targets on restricted execution paths, or re-check the originating authority for inner self-calls.

### AUD-AA-20: Do protocol paths that push ETH, or tokens with receiver hooks, to user addresses stay safe when a recipient classified as an EOA later has code?
- **Risk:** A 7702 delegate's `receive()`/`fallback` runs on a plain ETH transfer. Push-payment loops written for EOA recipients become reentrancy entry points: refunds, outbid refunds in auctions, airdrops, fee splits. A delegate whose `receive()` reverts, or uses more than 2300 gas under `transfer`/`send`, bricks batch payouts. An "is EOA" flag stored at registration goes stale because delegation can be added or cleared at any time (related SOL-Basics-Function-8, SOL-Basics-Payment-6).
- **Fix:** Use pull payments or CEI plus `nonReentrant` on every value push. Re-derive the recipient type at use time, or remove the EOA assumption. Test with a recipient whose `receive()` re-enters.
- **Refs:** 1 case(s)
  - https://ethereum.org/roadmap/pectra/7702/

### AUD-AA-21: Is a relayer or sponsor of 7702 or 4337 operations reimbursed before the sponsored account can invalidate the authorization or move the fee asset?
- **Risk:** A delegated account can bump its nonce, which invalidates the authorization tuple, or sweep the fee token mid-transaction. A relayer contract that collects its fee after execution then pays gas and recovers nothing, and the user can repeat this to grief it.
- **Fix:** Collect the fee before execution (escrow, bond, or paymaster pre-charge per AUD-AA-10). Rate-limit per authority.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-7702

## Safe modules and guards

### AUD-AA-22: Does every policy enforced by a Safe transaction guard also apply to module-initiated transactions?
- **Risk:** In Safe ≤ v1.4.1, `execTransactionFromModule` executes with no guard call at all. In v1.5.0, module transactions are checked only by a separate Module Guard (`setModuleGuard`), which must be set on its own. Any enabled module (recovery, allowance, automation, ERC-4337 module) bypasses transaction-guard policies such as spending limits, target allow-lists, or delegatecall bans. A module can also call `enableModule`, `setGuard`, or `changeThreshold` on the Safe itself. SOL-Integrations-GS-1 asks whether modules call the hooks; this item asks whether the policy holds when they don't.
- **Fix:** Enumerate enabled modules and treat each as a full-authority signer. On v1.5+, install a Module Guard that mirrors the transaction guard. Never enable a module whose call surface accepts caller-chosen `to`/`data`/`operation`.
- **Refs:** 2 case(s)
  - https://raw.githubusercontent.com/safe-global/safe-smart-account/v1.4.1/contracts/base/ModuleManager.sol
  - https://raw.githubusercontent.com/safe-global/safe-smart-account/main/contracts/base/ModuleManager.sol

### AUD-AA-23: Do guards and modules allow `operation == DelegateCall` only to an allow-list of audited libraries?
- **Risk:** A DelegateCall runs the target's code in the Safe's storage. It can overwrite slot 0 (the singleton/masterCopy), the owners and threshold, the module list, the guard slot, or the fallback handler. In February 2025 Bybit's Safe v1.1.1 signers approved a transaction with `operation = 1` that called `transfer(address,uint256)` on an attacker contract. That call rewrote slot 0 to an attacker implementation and the wallet was drained. A module that forwards a user-supplied `operation` byte gives delegatecall to whoever controls the module's input.
- **Fix:** In the guard, reject DelegateCall except to pinned libraries (e.g. MultiSendCallOnly). Hard-code `Operation.Call` in modules. Diff the slot-0 singleton, owners, threshold, modules, and guard before and after in tests.
- **Refs:** 1 case(s)
  - https://github.com/safe-global/safe-smart-account/issues/914

### AUD-AA-24: Can the Safe still remove or replace its guard when the guard reverts?
- **Risk:** The guard's `checkTransaction`/`checkAfterExecution` runs on every `execTransaction`, including the one that calls `setGuard(address(0))`. A buggy guard, an upgraded one, or one with a paused external dependency (oracle, registry, timelock, a proxy owned by someone else) bricks the Safe. A Module Guard bricks every module in the same way.
- **Fix:** Have the guard always allow self-calls to `setGuard`/`setModuleGuard` (or allow them after a delay). Keep an audited recovery path that does not route through the guard. Add a test where the guard reverts unconditionally and the Safe still recovers.
- **Refs:** 1 case(s)
  - https://docs.safe.global/reference-smart-account/guards/setGuard
