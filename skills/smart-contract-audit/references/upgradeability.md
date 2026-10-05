# Upgradeability

Profile-authored category (not part of the vendored Cyfrin checklist).

Total items: 19

## Storage layout

### AUD-Upgrade-1: Does an in-place upgrade move a proxy's implementation from OpenZeppelin `contracts-upgradeable` 4.x to 5.x, or across any other major version?
- **Risk:** 5.x moves each module's state out of sequential slots and into ERC-7201 namespaced structs. The new implementation reads empty structs, while the proxy's old slots still hold `_initialized`, `_owners`, `_balances`, `_roles` and `_status`. The result: ownership and balances read as zero, `Initializable` reads "never initialized" (so anyone can call `initialize` again), and the reentrancy status resets. Re-declaring the old variables or `__gap`s does not help, because 5.x code never reads the old slots. SOL-Basics-PU-9/PU-10 cover layout drift within one library version; this item is the cross-major case.
- **Fix:** Keep in-place upgrades on the deployed major version. To adopt 5.x, deploy a fresh proxy and migrate state explicitly, or write a bridging implementation that reads the legacy slots. Validate every upgrade against the deployed build as the reference layout.
- **Refs:** 1 case(s)
  - https://forum.openzeppelin.com/t/contract-upgrade-failed-because-variables-are-deleted-in-openzepplin-5-0/38341/2

### AUD-Upgrade-2: Does every `@custom:storage-location erc7201:<id>` annotation match the slot constant the code actually loads, and is each namespace id unique across the inheritance tree and every facet sharing the proxy?
- **Risk:** The annotation is metadata only. solc ≥0.8.20 records it in the AST and enforces nothing. Several mistakes all compile cleanly: a constant copied from another contract, a typo in the id, or a slot computed without the `- 1` and `& ~bytes32(uint256(0xff))` steps. Each one makes layout tooling validate a location the code never touches. Two modules that reuse one id (a copy-pasted base) read and write each other's fields.
- **Fix:** Recompute every constant as `keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff))`. Test vector: `example.main` gives `0x183a6125c38840424c4a85fa12bab2ab606c4b6d0e7cc73c0c06ba5300eab500`. Grep for duplicate ids across all code delegated to by one proxy, and pin each constant in a unit test.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-7201

### AUD-Upgrade-3: Does a custom proxy keep any of its own state (admin, implementation, pause flag) in sequentially allocated slots instead of ERC-1967 hashed slots?
- **Risk:** Proxy variables declared the normal way occupy slots 0..n, which are the same slots the implementation's first variables use. In Audius (July 2022), `AudiusAdminUpgradeabilityProxy` stored `proxyAdmin` in slot 0. That slot overlapped `Initializable`'s `initialized` and `initializing` bools, and the admin address's non-zero bytes read as `true` for both. As a result `initializer` always passed: the attacker re-initialized Governance, Staking and DelegateManagerV2, then moved 18,564,497 AUDIO from the treasury. SOL-Basics-PU-9 covers implementation-vs-implementation collisions; this item covers proxy-vs-implementation.
- **Fix:** Keep proxy state only at the ERC-1967 slots: implementation `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`, admin `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`, beacon `0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50`. Require `forge inspect <Proxy> storageLayout` to be empty.
- **Refs:** 2 case(s)
  - https://blog.audius.co/posts/audius-governance-takeover-post-mortem-7-23-22
  - https://eips.ethereum.org/EIPS/eip-1967

### AUD-Upgrade-4: When a version adds variables to a base contract that reserves a `__gap`, does the gap shrink by exactly the number of slots the additions occupy after packing?
- **Risk:** The gap absorbs slots, not variables. A `uint128` appended after an existing `uint128` packs into the same slot (gap unchanged); an `address` after a `uint256` takes a new slot; a struct takes its full slot count; a mapping or dynamic array takes one slot. Miscounting by one shifts every variable of every derived contract by one slot. The Audius remediation shows the arithmetic: three added slots shrank the reserved space from 50 to 47.
- **Fix:** Diff `forge inspect <Contract> storageLayout` between the deployed and the new build. Require that every pre-existing variable in every derived contract keeps its `slot` and `offset`.

### AUD-Upgrade-5: Does an upgrade change the size of a struct that is the element type of a storage array, or that is embedded by value ahead of other fields?
- **Risk:** Storage arrays place elements at a stride equal to the element's slot count. Appending a member to the element struct changes the stride, so every element at `i > 0` is decoded from another element's slots. A struct embedded by value in the middle of a layout or namespace struct pushes every field after it. Appending to a struct is layout-safe only when the struct is stored as a mapping value (each value starts at its own hashed slot) or is the last field of its namespace struct.
- **Fix:** Append members only to mapping-value structs or terminal fields. Freeze array element structs, and move growing per-element data to `mapping(uint256 => Struct)` with an explicit length, or to a parallel mapping.

### AUD-Upgrade-6: Does any storage variable, including a field of a namespace struct, hold an internal function type?
- **Risk:** A stored internal function value is a code offset (legacy pipeline) or a compiler-assigned sequential dispatch ID (via-IR) that is meaningful only to the bytecode that wrote it. After an upgrade, the stored value resolves to an unrelated internal function of the new implementation, or to a panic.
- **Fix:** Store an enum or an id and dispatch explicitly in code. Each implementation then resolves the id to its own functions.
- **Refs:** 1 case(s)
  - https://docs.soliditylang.org/en/latest/ir-breaking-changes.html

## Initialization across versions

### AUD-Upgrade-7: Does each version that needs new setup ship a `reinitializer(n)` with `n` above the current initialized version, executed atomically through `upgradeToAndCall(newImplementation, data)`?
- **Risk:** `reinitializer(n)` runs once while the stored version is below `n`, and the modifier places no restriction on who calls it. If the upgrade and the call to `initializeV2` happen in separate transactions, anyone can call it in between and set the new roles, oracles or fee recipients. Reusing a version number, marking the V2 function `initializer`, or an earlier `_disableInitializers()` reached through the proxy (which sets the version to `type(uint64).max`) makes the setup permanently uncallable, so the new module runs unconfigured. SOL-Basics-Initialization-3 covers the first deployment only.
- **Fix:** Pass the reinitializer calldata as `data` to `upgradeToAndCall` or `ProxyAdmin.upgradeAndCall`. Access-restrict reinitializers. In a fork test, assert `_getInitializedVersion()` before and after the upgrade.
- **Refs:** 1 case(s)
  - https://docs.openzeppelin.com/contracts/5.x/api/proxy

### AUD-Upgrade-8: Does every clone or proxy factory require `implementation.code.length > 0` and check initialized-only state in the same transaction?
- **Risk:** A call to an address without code succeeds and returns empty data. A clone or proxy pointing at an implementation that is not yet deployed (for example a CREATE2-precomputed address, or an implementation missing on a newly supported chain) therefore "initializes" with no effect. Once the implementation is deployed at that address, anyone can initialize the clone and own it. OpenZeppelin `Clones` does not check implementation code. The current OZ 5.x `ERC1967Proxy` reverts when constructed with empty `_data`, unless `_unsafeAllowUninitialized()` is overridden to return true. That override reopens the front-run window from SOL-Basics-Initialization-3.
- **Fix:** Require `implementation.code.length > 0` in the factory. Assert an initialized-only invariant (such as `owner() != address(0)`) right after initialization. Grep for every `_unsafeAllowUninitialized` override and justify each one.
- **Refs:** 1 case(s)
  - https://docs.openzeppelin.com/contracts/5.x/api/proxy

## Upgrade authority and proxy flavors

### AUD-Upgrade-9: Does every implementation in a UUPS proxy's upgrade path keep a working `upgradeToAndCall`, with `_authorizeUpgrade` overridden and `proxiableUUID()` returning the ERC-1967 implementation slot?
- **Risk:** In UUPS, the upgrade logic lives in the implementation. An upgrade to a version that drops `UUPSUpgradeable`, overrides `upgradeToAndCall` without the upgrade path, or inherits a `_authorizeUpgrade` that always reverts freezes the proxy permanently. OZ rejects implementations whose `proxiableUUID()` differs from the slot (`UUPSUnsupportedProxiableUUID`), but a hand-rolled UUPS that skips that check accepts any target, including an EOA or a non-upgradeable contract. In OZ 5.x, `UPGRADE_INTERFACE_VERSION` "5.0.0" means only `upgradeToAndCall` exists, so scripts that call `upgradeTo` revert. SOL-Basics-PU-4 covers who may call `_authorizeUpgrade`; this item covers whether upgrading keeps working.
- **Fix:** In a fork test, upgrade V1 to V2, then V2 to a dummy V3. That proves V2 can still upgrade. Keep the `proxiableUUID` check in any custom UUPS.
- **Refs:** 1 case(s)
  - https://docs.openzeppelin.com/contracts/5.x/api/proxy

### AUD-Upgrade-10: Does deployment of an OZ 5.x `TransparentUpgradeableProxy` pass the intended EOA, multisig or timelock as `initialOwner`, rather than an existing `ProxyAdmin`?
- **Risk:** In 5.x, the proxy constructor deploys its own `ProxyAdmin`, and that admin is immutable. `initialOwner` becomes the owner of the new `ProxyAdmin`. Passing an existing `ProxyAdmin` address (the 4.x habit) makes the new admin owned by a contract that can only call `upgradeAndCall` on proxies, so it cannot drive the new admin, and upgrades are lost for good. Scripts that call `changeAdmin` or `upgrade(proxy, impl)` from 4.x also fail against 5.x.
- **Fix:** After deployment, read the ERC-1967 admin slot of the proxy and assert `ProxyAdmin(admin).owner()` equals the intended governance address. Then run one no-op upgrade on a fork.
- **Refs:** 1 case(s)
  - https://docs.openzeppelin.com/contracts/5.x/api/proxy

### AUD-Upgrade-11: Does any implementation write the ERC-1967 beacon slot, or does a beacon's `implementation()` depend on `msg.sender` or mutable per-caller state?
- **Risk:** OZ `BeaconProxy` fixes its beacon at construction, in an immutable, and only mirrors the address into the beacon slot. An implementation that writes that slot changes what explorers and monitors report without changing the proxy's routing. A custom beacon proxy that reads the slot lets implementation logic re-route the proxy. A beacon whose `implementation()` varies by caller can serve different logic to different proxies, which ERC-1967 says it SHOULD NOT do. One beacon owner upgrades every proxy behind it in a single transaction.
- **Fix:** Keep `implementation()` a pure storage read. Grep implementations for writes to `0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50`. Rate the beacon owner's trust against the most valuable proxy it serves.
- **Refs:** 2 case(s)
  - https://eips.ethereum.org/EIPS/eip-1967
  - https://docs.openzeppelin.com/contracts/5.x/api/proxy

### AUD-Upgrade-12: Does a non-transparent proxy (a custom proxy, or a diamond with immutable functions) expose any external selector that also exists in its implementation or facets?
- **Risk:** A selector the proxy implements itself never reaches the fallback, so the matching implementation function is shadowed for every caller. Four-byte selectors are cheap to brute-force, so a proxy-level admin function can be made to collide with an innocuous-looking implementation function. SOL-Basics-VI-OVI-7 covers only the OZ Transparent proxy before 4.8.3.
- **Fix:** Compare `forge inspect <Proxy> methodIdentifiers` with the identifiers of every implementation or facet, and require no overlap. For UUPS, keep the proxy free of external functions apart from the fallback.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-1967

## Diamonds (ERC-2535)

### AUD-Upgrade-13: Is `diamondCut`'s `(_init, _calldata)` delegatecall limited to the cut authority, and does `_init` always point at audited, non-upgradeable initializer code that exists?
- **Risk:** After applying the cut, the diamond delegatecalls `_init` with `_calldata`. That is arbitrary code running against the diamond's whole storage: it can rewrite ownership, selector routing and balances. `_init == address(0)` skips execution. A delegatecall to an address without code succeeds silently unless the implementation checks for code. An `_init` that is itself a proxy, or a contract that can be redeployed, lets its owner change what a reviewed cut will execute.
- **Fix:** Restrict `diamondCut` to the timelocked owner. Require `_init.code.length > 0` whenever `_init != address(0)`. Review `_calldata` and the `_init` bytecode hash as part of each upgrade proposal.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-2535

### AUD-Upgrade-14: Does every facet keep state only in its own diamond-storage (or ERC-7201) struct, or in the single shared `AppStorage` struct at slot 0, with no ordinary state variables?
- **Risk:** All facets execute against the diamond's storage. A facet that declares ordinary state variables, or inherits a non-upgradeable base such as `Ownable`, writes slots 0..n, the same slots other facets use. The facets then corrupt each other's state, and the damage surfaces only when the colliding facet is cut in.
- **Fix:** Require `forge inspect <Facet> storageLayout` to be empty for every facet, or to show only the identical `AppStorage` declaration. Recompute every diamond-storage position constant, and check each one is unique.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-2535

### AUD-Upgrade-15: Does the `diamondCut` implementation enforce the ERC-2535 action rules, and does the loupe report exactly the live selector-to-facet mapping?
- **Risk:** The standard requires `Add` to revert when the selector is already mapped, `Replace` to revert when the selector is unset or already maps to the same facet, `Remove` to revert when the selector is unset, and any replace or remove of an immutable function to revert. An implementation that skips these checks lets an `Add` silently overwrite a live selector, or lets a cut remove `diamondCut` itself and freeze all future upgrades. A loupe that has drifted from the routing table hides which code is live from reviewers and monitors.
- **Fix:** Test each revert condition, and fuzz a property that `facets()` and `facetAddress(selector)` agree with routing for every selector after arbitrary cut sequences.
- **Refs:** 1 case(s)
  - https://eips.ethereum.org/EIPS/eip-2535

## Code replacement

### AUD-Upgrade-16: Does governance, an allowlist or an upgrade process approve a contract by address alone when the code at that address could change before execution?
- **Risk:** A CREATE2-deployed factory that self-destructs resets its nonce. After redeployment, CREATE from the factory reproduces the same child addresses with different code. In the Tornado Cash governance takeover (May 2023), voters approved a proposal contract. Its code was then destroyed and replaced, at the same address, with code that took over governance. EIP-6780 limits SELFDESTRUCT to deleting code only in the transaction that created the contract. That closes cross-transaction morphing on chains that ship it, and it breaks "upgrade by selfdestruct + redeploy" patterns, which can no longer clear the old code. Chains that have not adopted EIP-6780 still allow morphing. SOL-Basics-VI-EAI-1 refers to EIP-4758; EIP-6780 is the variant Ethereum activated.
- **Fix:** Approve `(address, codehash)` pairs, and re-check `target.codehash` at execution time. For each deployment chain, confirm whether EIP-6780 is active before treating code as immutable.
- **Refs:** 2 case(s)
  - https://eips.ethereum.org/EIPS/eip-6780
  - https://github.com/pcaversaccio/tornado-cash-exploit

## Upgrade-time behavior

### AUD-Upgrade-17: Do in-flight items created under the old implementation (queued withdrawals, pending orders, timelocked calls, signed messages) still decode with the same meaning under the new one?
- **Risk:** The new implementation reads old storage and old signatures with new rules. Reordering an enum, retyping a struct field, or changing units (shares to assets, a different decimals base) makes pending entries pay out or execute differently. Changing what a signed struct means without changing its EIP-712 typehash or domain `version` lets old signatures authorize new semantics. Changing the domain unintentionally invalidates every outstanding signature.
- **Fix:** Keep enums append-only. Migrate queued data inside the `upgradeToAndCall` payload. Bump the EIP-712 `version` whenever the semantics of a signed struct change. Replay real pending items from a fork against the new implementation.

### AUD-Upgrade-18: Is an EIP-712 domain separator, or any other value derived from `address(this)`, computed in an implementation constructor or stored as an immutable?
- **Risk:** In the implementation constructor, `address(this)` is the implementation, not the proxy. A domain separator cached there binds signatures to the implementation's address. Every proxy and clone sharing that implementation then accepts the others' signatures (cross-instance replay), and an upgrade that changes the cached value invalidates outstanding signatures. SOL-Signature-1 covers nonce and `chainid`, not `verifyingContract`.
- **Fix:** Compute the separator at runtime from `address(this)` and `block.chainid`. Alternatively, use OZ `EIP712`, which rebuilds the separator when `address(this)` or `chainid` differ from the cached values.

### AUD-Upgrade-19: Is every `@custom:oz-upgrades-unsafe-allow` annotation (`constructor`, `state-variable-immutable`, `delegatecall`, `selfdestruct`, and the rest) individually justified?
- **Risk:** Each annotation switches off an upgrade-safety check for its scope. A blanket `unsafe-allow` can hide the very bugs the plugin exists to catch: an immutable that must differ per proxy (SOL-Basics-PU-7), a constructor that sets state the proxy never sees (SOL-Basics-PU-1), or a delegatecall to a caller-controlled target (SOL-Basics-PU-6).
- **Fix:** List every annotation and write down why the suppressed check cannot fire in that scope. Constructors should contain only `_disableInitializers()` and immutable assignments that hold for every proxy.
