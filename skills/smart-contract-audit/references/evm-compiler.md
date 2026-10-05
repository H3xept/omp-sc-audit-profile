# EVM and compiler semantics

Profile-authored category (not part of the vendored Cyfrin checklist).

Total items: 19

## Caller and code introspection

### AUD-EVM-1: Does any access or flow decision depend on `addr.code.length`, `extcodesize` or `extcodehash` to tell an EOA from a contract?
- **Risk:** `code.length == 0` holds for an EOA, but also for a contract whose constructor is still running, an address that a CREATE2 deployment will later fill, a precompile, and a contract destroyed earlier in the same transaction. So a "must be an EOA" check admits contracts calling from their constructors. Under EIP-7702, a delegated EOA has code `0xef0100 || delegate`: EXTCODESIZE returns 23 and EXTCODEHASH hashes the indicator. "EOA-only" paths therefore reject 7702 users, and "has code, so no private key" assumptions break, because a delegated EOA still signs permits and can re-delegate at any time. SOL-Basics-Function-8 names the question; this item gives the opcode-level cases.
- **Fix:** Take caller-type checks out of security decisions. Authorize by signature or by allowlist instead. Where a check is unavoidable, recognise 7702 by matching the 23-byte `0xef0100` prefix, and document the constructor and counterfactual-address bypass.
- **Refs:** 1 case(s)
  - https://raw.githubusercontent.com/ethereum/EIPs/master/EIPS/eip-7702.md

### AUD-EVM-2: Does a `require(msg.sender == tx.origin)` guard carry an atomicity assumption, such as "no flash loan", "no sandwich in one tx" or "no reentrancy from a contract"?
- **Risk:** Before EIP-7702, `msg.sender == tx.origin` held only in the top call frame, so it implied no intermediary code. With 7702, an EOA sends a transaction to itself, its delegated code runs a batch (flash-borrow, manipulate, call the target, repay), and the target still sees `msg.sender == tx.origin`. The EIP itself names this broken invariant. SOL-Basics-Function-8 predates 7702.
- **Fix:** Enforce atomicity properties directly: same-block deposit/withdraw locks, TWAP or oracle bounds, and reentrancy guards. Do not rely on caller type.
- **Refs:** 1 case(s)
  - https://raw.githubusercontent.com/ethereum/EIPs/master/EIPS/eip-7702.md

## External calls and gas

### AUD-EVM-3: Does a call whose failure must not revert the caller (keeper, relayer, liquidation, cross-chain receiver, payout loop) let Solidity copy the callee's returndata?
- **Risk:** `(bool ok, ) = target.call(data)` still emits RETURNDATACOPY of the full returndata into memory. This was checked with solc 0.8.35, both legacy and via-IR. So do `(bool ok, bytes memory r) = ...`, `catch (bytes memory reason)`, and revert bubbling. The callee runs with at most 63/64 of the gas, but returning a large buffer costs it little. The caller then pays quadratic memory expansion from its remaining 1/64 and reverts out of gas, so a single hostile recipient bricks the batch, the message or the liquidation (a "returnbomb"). SOL-EC-9 names the symptom; this item is the exact codegen trigger.
- **Fix:** Use an assembly call with `outsize = 0`, then `returndatacopy` at most a fixed cap, as in the `ExcessivelySafeCall` pattern. Avoid `catch (bytes memory)` on untrusted callees.

### AUD-EVM-4: When a contract records the outcome of a gas-limited subcall (marks a message executed or failed, consumes a nonce, deletes a queue entry), does it verify that the callee actually received the gas the caller specified?
- **Risk:** EIP-150 caps forwarded gas at 63/64 of what remains. A relayer can therefore choose the transaction gas so that the inner call runs out of gas while the outer frame keeps 1/64, enough to store "failed" and finish. The user's message is then permanently consumed with no effect. A `try/catch` that treats every revert as a business failure has the same hole. SOL-AM-GA-2 and SOL-Heuristics-5 state the risk; this item gives the check.
- **Fix:** Before the call, require `gasleft() >= gasLimit * 64 / 63 + overhead`. Alternatively, after a failed call require `gasleft() > gasLimit / 63`, and revert the whole transaction otherwise. Fuzz the outer gas limit in a test.

### AUD-EVM-5: Is the output of `ecrecover` (or a hand-rolled `staticcall` to precompile `0x01`) compared with a stored signer that can be `address(0)`?
- **Risk:** For an invalid signature, the precompile returns empty data and `ecrecover` evaluates to `address(0)`. If the expected signer is an unset owner, an uninitialized delegate, or a mapping entry that defaults to zero, `ecrecover(...) == signer` succeeds for garbage signatures. SOL-Signature-2 covers malleability, and SOL-Basics-VI-SVI-44 covers only pre-0.4.14 input validation.
- **Fix:** Require `recovered != address(0)`, or use OZ `ECDSA.recover`, which reverts on a zero result. Also reject `signer == address(0)` wherever signers are configured.

## Transient storage (EIP-1153)

### AUD-EVM-6: Does every transient slot that the code sets get reset before control can return to another caller in the same transaction?
- **Risk:** Transient storage clears at the end of the transaction, not at the end of the call. When a lock, "callback expected" flag, cached price or authorized-caller slot is left set, every later call in the same transaction (a multicall, a batch, a 7702 bundle, a second top-level call through a router) sees that stale value. The result is either a stuck lock (DoS for the rest of the transaction) or a stale authorization that a different caller can use. A revert discards the frame's transient writes, but a successful early `return` does not.
- **Fix:** Clear each slot on every exit path, using a modifier or a `try/finally`-style structure. Key flags by `msg.sender` or by a nonce where the value is per-caller. Test two consecutive calls within one transaction through a multicall harness.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-1153

### AUD-EVM-7: Does any code assume that a 2300-gas stipend (`transfer`/`send`) prevents state changes, or does a delegatecalled module use a transient slot that its host also uses?
- **Risk:** TSTORE costs 100 gas and has no stipend check, so a recipient running on a 2300-gas stipend can now change transient state, such as a reentrancy flag or a callback marker read later in the transaction. Under DELEGATECALL, transient storage belongs to the caller. A library or module that delegatecalls and uses a fixed transient slot (for example a transient reentrancy lock) therefore shares that slot with the host: the module either sees the host's lock as already held (DoS), or clears it (reentrancy). TSTORE inside STATICCALL reverts, so a view path that writes transient state fails.
- **Fix:** Treat stipend calls as fully reentrant for transient state. Namespace transient slots per module with ERC-7201-style derivation. Keep TSTORE out of any path reachable from `view` or STATICCALL.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-1153

### AUD-EVM-8: Is the code compiled via-IR with solc 0.8.28–0.8.33 for an EVM version of cancun or later, and does it `delete` a transient variable while also clearing a persistent variable of the same value type?
- **Risk:** This is the `TransientStorageClearingHelperCollision` bug, rated high. Persistent and transient clears of the same type share one Yul helper, so one of them emits the wrong opcode. Example: `delete` on a transient lock emits `sstore(slot, 0)`, wiping a persistent variable such as `owner`; or a persistent delete becomes `tstore` and never clears storage. Implicit clears trigger it too, including `.pop()`, array shrinking, struct `delete`, and clears inside inherited or library code.
- **Fix:** Upgrade to ≥0.8.34. On affected versions, assign the zero value (`lock = false`) instead of `delete` for transient variables. Then inspect `forge inspect <C> irOptimized` and confirm that every clear helper emits `sstore` for persistent variables and `tstore` for transient ones.
- **Refs:** 1 case(s)
  - https://blog.soliditylang.org/2026/02/18/transient-storage-clearing-helper-collision-bug/

## Compiler version and pipeline

### AUD-EVM-9: Does the compiler's `evm_version` match the oldest hardfork supported by every deployment chain?
- **Risk:** The latest solc defaults to `osaka`. That target can emit `clz` (Osaka), `mcopy`/`tstore`/`tload` (Cancun) and `push0` (Shanghai). On a chain that lacks an opcode, it is an invalid instruction. If the constructor executes it, deployment fails. If it sits only on certain runtime paths, the code deploys and then reverts only on those paths, which can leave withdrawals or liquidations stuck while deposits work. SOL-McCc-12 covers only PUSH0. Arbitrum, for example, gained PUSH0 only with ArbOS 11.
- **Fix:** Pin `evm_version` in `foundry.toml` to the minimum hardfork across declared chains. Run the fork test suite on every chain's RPC. Diff the deployed bytecode against a build for the pinned target.
- **Refs:** 2 case(s)
  - https://docs.soliditylang.org/en/latest/using-the-compiler.html
  - https://docs.arbitrum.io/arbitrum-essentials/arbitrum-vs-ethereum/solidity-support

### AUD-EVM-10: When the build uses via-IR (or switches pipelines between versions), does any code depend on a behavior that differs between the legacy and IR pipelines?
- **Risk:** Under via-IR, state-variable initializers interleave with constructors per contract in linearized order, so an initializer that reads a value a base constructor sets now sees the set value instead of zero. `delete` on a storage struct zeroes every slot it touches, including padding that an upgrade used for new members. Modifiers that execute `_;` more than once re-initialize parameters and return variables on each execution. `addmod`/`mulmod` arguments evaluate left-to-right instead of right-to-left. Allocations that push the free memory pointer past `type(uint64).max` revert instead of running out of gas. A test suite run on one pipeline does not cover a deployment built with the other.
- **Fix:** Run the test suite with the exact pipeline, optimizer runs and `evm_version` used for deployment. Grep for multi-`_;` modifiers, side effects in `addmod`/`mulmod` arguments, and state initializers that call functions.
- **Refs:** 1 case(s)
  - https://docs.soliditylang.org/en/latest/ir-breaking-changes.html

### AUD-EVM-11: Is the code built with the legacy pipeline (no via-IR) and solc <0.8.37, and does it `delete b[i]` on a memory `bytes` (including `bytes(str)[i]`)?
- **Risk:** This is `MemoryByteArrayElementDeleteClearsWholeWord`. The element delete is compiled as an MSTORE of 32 zero bytes, which clears up to 31 following bytes. Those bytes may belong to the same buffer or to the next allocation, such as an `abi.encodePacked`/`concat` result with no padding. The effect is silently corrupted calldata, signatures or hash preimages that are built in memory.
- **Fix:** Replace the delete with `b[i] = 0`, or upgrade to ≥0.8.37.
- **Refs:** 1 case(s)
  - https://blog.soliditylang.org/2026/09/10/memory-byte-array-element-delete-clears-whole-word-bug/

### AUD-EVM-12: Is the code compiled via-IR with solc 0.7.2–0.8.36, and does its call graph contain mutual recursion (A calls B calls A) while the stack-limit evader moves variables to memory?
- **Risk:** Two bugs apply. `UnsoundSpillInMutualRecursion` (fixed in 0.8.36) spills a recursive function's locals to fixed memory offsets, so the recursive calls overwrite one another. `SpillSlotCollisionAcrossMutualRecursion` (fixed in 0.8.37) assigns the same offset to locals of two functions that are active at the same time. In both cases locals silently take another frame's values. From 0.8.21 onward this happens whether or not the optimizer is enabled. Recursive tree, sorted-list and path-finding code fits the shape.
- **Fix:** Upgrade to ≥0.8.37, or break the mutual recursion into iteration. Compare results from the legacy and IR builds on recursive inputs.
- **Refs:** 2 case(s)
  - https://blog.soliditylang.org/2026/07/09/unsound-spill-in-mutual-recursion-bug/
  - https://raw.githubusercontent.com/ethereum/solidity/develop/docs/bugs.json

### AUD-EVM-13: With solc 0.8.29–0.8.35, does any contract use a `layout at <slot>` clause whose base sits close enough to the end of storage that the compiler warns?
- **Risk:** This is `InheritanceOrderReversalOnStorageEndWarning`, in both pipelines. Emitting the storage-end warning (base location within the last 2**64 slots) reverses the C3 linearization. Constructor order, `super` chains and virtual-override resolution then run in reverse, so a different override of `_update` or `_authorize` wins, and the compiler gives no error.
- **Fix:** Upgrade to ≥0.8.36, or move the base away from the end of storage. Assert, through tests, which override executes for every overridden hook.
- **Refs:** 1 case(s)
  - https://blog.soliditylang.org/2026/07/09/inheritance-order-reversal-on-storage-end-warning-bug/

### AUD-EVM-14: Does the exact compiler version, combined with the conditions in `bugs.json` (`viaIR`, `evmVersion`, `yulOptimizer`, ABI coder), match any bug that no SOL-Basics-VI-SVI item lists?
- **Risk:** The vendored SVI list stops before the recent entries. `LostStorageArrayWriteOnSlotOverflow` (fixed in 0.8.32): clearing or copying arrays that straddle the end of storage silently keeps old data, which is reachable with custom `layout at` bases. `MisorderedNamedParametersInRequireWithCustomErrors` (via-IR, 0.8.26–0.8.36): named-argument custom errors in `require` are encoded in call-site order, so off-chain decoders and tests that match error data read the wrong fields. `VerbatimInvalidDeduplication` (0.8.5–0.8.22): Yul `verbatim` blocks are wrongly merged.
- **Fix:** Look up the pinned version in `bugs_by_version.json`, filter by each bug's `conditions`, and add every match to the findings, or justify why the trigger is absent.
- **Refs:** 1 case(s)
  - https://raw.githubusercontent.com/ethereum/solidity/develop/docs/bugs.json

## Inline assembly

### AUD-EVM-15: Does each `assembly ("memory-safe")` block (or `/// @solidity memory-safe-assembly`) touch only memory it allocated by bumping `0x40`, Solidity-allocated memory, scratch space `0x00–0x3f`, or temporary memory above the free memory pointer that it never relies on later?
- **Risk:** The annotation lets the compiler's stack-limit evader move stack variables into a memory region it reserves at fixed offsets. Three patterns break that region or the memory layout: a block that writes to absolute offsets it never allocated (for example `mstore(0x80, x)`); a write to `0x60`, the zero slot; and an unbounded copy to offset 0 such as `returndatacopy(0, 0, returndatasize())`, which runs past scratch space over the free memory pointer at `0x40`. Any of them silently corrupts spilled variables, empty arrays or later allocations. The Solidity docs class a false annotation as undefined behavior that tests can hardly discover. SOL-Basics-Math-11 covers assembly arithmetic only.
- **Fix:** Classify every annotated block against the four permitted regions. Drop the annotation, or allocate with `mstore(0x40, add(ptr, size))` before writing. Run the suite with via-IR and optimizer settings that force stack-to-memory spills.
- **Refs:** 1 case(s)
  - https://docs.soliditylang.org/en/latest/assembly.html

### AUD-EVM-16: Does assembly read sub-256-bit Solidity values (`address`, `uint8`, `bool`, `bytesN`, `int<N>`) or calldata words without masking or sign-extending them?
- **Risk:** Solidity does not guarantee clean high-order bits for types narrower than 256 bits, and the legacy and IR pipelines clean at different points. Dirty bits make `eq` comparisons of addresses fail, change the result of `keccak256` over packed values, and make negative `int<N>` values read as huge unsigned numbers. Calldata loaded with `calldataload` is never validated.
- **Fix:** Mask with `and(x, 0xffffffffffffffffffffffffffffffffffffffff)` for addresses, `and(x, 0xff)` for `uint8`, and `signextend(k, x)` for `int<8(k+1)>`. Alternatively, pass clean `uint256` values into assembly.
- **Refs:** 1 case(s)
  - https://docs.soliditylang.org/en/latest/assembly.html

### AUD-EVM-17: Does assembly `mload` memory it did not write, or assume memory above the free memory pointer is zero?
- **Risk:** Memory is not guaranteed to be zero beyond the free memory pointer, because earlier code may have used it as scratch space. Code that allocates a buffer, writes only some words and hashes or returns the whole buffer leaks or includes stale data, which changes signature digests and storage keys. The free memory pointer lives at `0x40`, and allocation starts at `0x80`.
- **Fix:** Zero or fully write every word before reading or hashing it. Compute lengths from bytes actually written.
- **Refs:** 1 case(s)
  - https://docs.soliditylang.org/en/latest/assembly.html

## Other languages and opcode semantics

### AUD-EVM-18: Is any Vyper contract in scope, or any integrated Vyper pool or vault, compiled with Vyper 0.2.15, 0.2.16 or 0.3.0 and using `@nonreentrant`?
- **Risk:** Those compilers allocated a separate lock slot for each function, regardless of the key. `@nonreentrant("lock")` therefore protects each function only against itself, and cross-function reentrancy stays open. Curve pools built with these versions were drained through this on 2023-07-30. Protocols that integrate such pools inherit the open cross-function reentrancy.
- **Fix:** Read the `# @version` pragma or the verified compiler of each Vyper dependency. Treat affected pools as having no lock. Require ≥0.3.1 for in-scope code.
- **Refs:** 1 case(s)
  - https://hackmd.io/@vyperlang/HJUgNMhs2

### AUD-EVM-19: Does any logic rely on SELFDESTRUCT deleting code or storage, burning ETH, or resetting a contract's nonce, on a chain that has EIP-6780?
- **Risk:** Under EIP-6780, SELFDESTRUCT on a contract not created in the same transaction only sends its balance; code, storage and nonce stay. As a result, "kill switches" leave the contract callable, storage-reset-by-redeploy leaves stale storage, CREATE2 redeploy-at-same-address fails, and when the beneficiary is the contract itself the ETH is not burned and remains withdrawable. The old semantics still apply when creation and selfdestruct happen in the same transaction. SOL-Basics-VI-EAI-1 refers to EIP-4758; EIP-6780 is the variant that shipped.
- **Fix:** Replace self-destruct lifecycles with an explicit `disabled` flag checked on every entry point. Treat code and storage as permanent.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-6780
