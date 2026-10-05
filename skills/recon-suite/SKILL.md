---
name: recon-suite
description: Build a Recon/Chimera invariant-testing scaffold in a Foundry repo. Use when setting up stateful invariant testing from zero, writing Setup, TargetFunctions, Properties, BeforeAfter ghosts, CryticTester or CryticToFoundry, wiring actors and assets, adding clamped handlers for unreachable code, or generating handlers with recon.json. Triggers on recon, chimera, invariant scaffold, CryticTester, target handlers, ghost variables, asActor, clamped handler, actor manager.
---

# Recon scaffold

One inheritance tree, two entry points: `CryticTester` for the fuzzers and `CryticToFoundry` for Forge replay. Building it well is what makes every later campaign and reproducer cheap. Run the campaigns with `skill://fuzz-echidna-medusa`.

## Bootstrap

```bash
forge install foundry-rs/forge-std
forge install Recon-Fuzz/setup-helpers   # vendors chimera under lib/setup-helpers/lib/chimera
mkdir -p test/recon/targets test/recon/mocks
```

```text
# remappings.txt — the minimum viable set
forge-std/=lib/forge-std/src/
@chimera/=lib/setup-helpers/lib/chimera/src/
@recon/=lib/setup-helpers/src/
setup-helpers/=lib/setup-helpers/src/
```

`@chimera/` is the framework; `@recon/` is setup-helpers (`ActorManager`, `AssetManager`, `Utils`, `MockERC20`). Installing `Recon-Fuzz/chimera` standalone as well adds an unprefixed `chimera/=lib/chimera/src/` mapping; one copy is enough.

## The files

| File | Responsibility |
| --- | --- |
| `test/recon/Setup.sol` | deploy the system, register actors and assets, approvals, `asActor` / `asAdmin` |
| `test/recon/BeforeAfter.sol` | `Vars` ghost struct, `_before` / `_after`, `updateGhosts` modifiers |
| `test/recon/Properties.sol` | `invariant_*` and `property_*` checks, no state mutation |
| `test/recon/TargetFunctions.sol` | composes every `targets/*` group alphabetically |
| `test/recon/targets/<Contract>Targets.sol` | one handler group per system contract |
| `test/recon/mocks/*.sol` | adversarial tokens: fee-on-transfer, false-on-failure, rebasing |
| `test/recon/CryticTester.sol` | Echidna and Medusa entry point |
| `test/recon/CryticToFoundry.sol` | Forge replay entry point |

Handlers are named `<contract>_<function>`; checks are `invariant_*`, `property_*`, or `doomsday_*`.

## The two entry points

```solidity
// CryticTester.sol
import { CryticAsserts } from '@chimera/CryticAsserts.sol';
import { TargetFunctions } from './TargetFunctions.sol';

contract CryticTester is TargetFunctions, CryticAsserts {
    constructor() payable {
        setup();
    }
}
```

```solidity
// CryticToFoundry.sol
import { FoundryAsserts } from '@chimera/FoundryAsserts.sol';
import { Test } from 'forge-std/Test.sol';
import { TargetFunctions } from './TargetFunctions.sol';

contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }
}
```

Both compose the same `TargetFunctions`. Only the assert backend and the setup trigger differ: `CryticAsserts` turns a failed check into `emit Log(reason); assert(false)` for the fuzzers, `FoundryAsserts` maps it to `assertEq`-family calls for Forge. The diamond resolves `Asserts` to whichever concrete implementation the entry point mixes in, because it is most derived. That is the property that makes any fuzzer sequence transcribable into a `forge test` with full traces.

Keep the constructor `payable` so the fuzzers can fund the tester.

## Chimera API

```solidity
// @chimera/Asserts.sol — the whole surface
function gt(uint256 a, uint256 b, string memory reason) internal virtual;
function gte(uint256 a, uint256 b, string memory reason) internal virtual;
function lt(uint256 a, uint256 b, string memory reason) internal virtual;
function lte(uint256 a, uint256 b, string memory reason) internal virtual;
function eq(uint256 a, uint256 b, string memory reason) internal virtual;
function t(bool b, string memory reason) internal virtual;
function between(uint256 value, uint256 low, uint256 high) internal virtual returns (uint256);
function between(int256 value, int256 low, int256 high) internal virtual returns (int256);
function precondition(bool p) internal virtual;
```

- `precondition` becomes `require(p)` under the fuzzers and `vm.assume(p)` under Forge. Use it to discard uninteresting inputs; a plain `require` in a handler does the same but is invisible to Forge's assumption accounting.
- `between` folds an out-of-range value into `[low, high]` by modulo instead of discarding it, so entropy is never wasted.
- `BaseSetup` declares one hook: `function setup() internal virtual;`.
- `import { vm } from '@chimera/Hevm.sol'` gives the cheatcode interface at the standard address, so the same handler body works under Echidna, Medusa, and Forge. Import it from Chimera rather than `forge-std/Vm`.

## Setup: actors, assets, approvals

`ActorManager` makes `address(this)` the default actor and keeps a set; `AssetManager` owns the current asset and mints and approves for every actor.

```solidity
abstract contract Setup is BaseSetup, ActorManager, AssetManager, Utils {
    YourSystem system;

    function setup() internal virtual override {
        system = new YourSystem();

        _newAsset(18);                          // fresh MockERC20, becomes the current asset
        _addAsset(address(new MockFoTToken()));  // adversarial tokens join the rotation

        _addActor(address(0x101));               // address(this) is already actor 0
        _addActor(address(0x202));

        address[] memory approvalArray = new address[](1);
        approvalArray[0] = address(system);
        _finalizeAssetDeployment(_getActors(), approvalArray, type(uint88).max);
    }

    modifier asAdmin() {
        vm.prank(address(this));
        _;
    }

    modifier asActor() {
        vm.prank(address(_getActor()));
        _;
    }
}
```

- `_getActor()` and `_getAsset()` are the single source of who acts and which token. Read them in handlers rather than storing addresses.
- `_finalizeAssetDeployment` mints the amount to every actor and approves every address in the array. `type(uint88).max` keeps balances large while staying far from overflow.
- Expose `switchActor(uint256 entropy)` and `switch_asset(uint256 entropy)` handlers in a `ManagersTargets` group so the fuzzer explores multi-actor sequences. Both managers revert on out-of-range entropy, which keeps them usable from Halmos.
- `asAdmin` pranks `address(this)`, which is also the default actor, so the tester is the privileged account.

Seed a sentinel into storage that no legitimate operation touches, then assert it stayed put. A canary catches corruption without predicting a value:

```solidity
bytes constant DIRTY_FLAG = hex"ffff...ffff";
for (uint256 i = FIRST_UNUSED; i < LAST; i++) {
    system.debugWriteSlot(i, DIRTY_FLAG);
}
```

## Ghosts

```solidity
abstract contract BeforeAfter is Setup {
    enum OpType { GENERIC, CLAMPED_CALL }

    struct Vars {
        uint256 totalShares;
        uint256 totalAssets;
    }

    Vars internal _before;
    Vars internal _after;
    OpType internal currentOperation;

    modifier updateGhosts() {
        currentOperation = OpType.GENERIC;
        __before();
        _;
        __after();
    }

    modifier updateGhostsWithType(OpType op) {
        currentOperation = op;
        __before();
        _;
        __after();
    }

    function __before() internal { _before.totalShares = system.totalShares(); /* ... */ }
    function __after() internal { _after.totalShares = system.totalShares(); /* ... */ }
}
```

`Vars` holds only state a property actually diffs. `currentOperation` lets one property fire for a specific operation class without a separate check per handler.

## Handlers

```solidity
abstract contract YourSystemTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    function system_deposit(uint128 amount) public updateGhosts asActor {
        system.deposit(amount);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}
```

Every group is `abstract contract XTargets is BaseTargetFunctions, Properties`. Rules that keep a suite debuggable:

1. Mutating handler gets `asActor`, or `asAdmin` for a privileged path. A handler with no prank runs as the tester and silently grants itself admin.
2. Add `updateGhosts` wherever a property diffs state through that path.
3. Narrow amount parameters to `uint128` or `uint64`. Full `uint256` entropy overflows the harness itself, especially with fee-on-transfer or rebasing tokens, and reports a harness bug as a protocol bug.
4. One file per system contract, imported and inherited in alphabetical order in `TargetFunctions`. Alphabetical order makes a C3 linearization error readable.
5. Pass `msg.value` explicitly on payable paths: `system.run{ value: msg.value }(args)` on a `payable` handler.
6. Keep the two sentinel comments intact; the generator injects between them.

`TargetFunctions` itself is pure composition:

```solidity
abstract contract TargetFunctions is ManagersTargets, YourSystemTargets {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}
```

## Property taxonomy

| Shape | Placement | Checked |
| --- | --- | --- |
| global truth over public state | `invariant_*` in `Properties`, declared `returns (bool)` with no arguments | after every transaction under Medusa property mode |
| transition over `_before` / `_after` | `property_*` in `Properties` | whenever called |
| operation must never revert | `doomsday_*` handler in `targets/DoomsdayTargets.sol` | whenever called |

A doomsday handler asserts liveness and must leave no trace, which the `stateless` modifier guarantees:

```solidity
/// Makes a handler have no side effects: asserts already ran, and the revert
/// keeps the fuzzer from counting it as a state transition.
modifier stateless() {
    _;
    revert('stateless');
}

function doomsday_withdraw_never_reverts(uint128 amount) public stateless {
    try system.withdraw(amount) {
    } catch {
        t(false, "withdraw reverted for a solvent actor");
    }
}
```

Expose decode or view helpers as `external pure` so a handler can call them through `this.` inside a `try`.

## Clamped handlers

When blind calldata fuzzing cannot reach a flow — bespoke byte formats, multi-step command pipelines, cross-contract calls chosen by selector — degrade the fuzzer's entropy into a whitelist instead of widening the search.

```solidity
function clampedAddToDictionary(uint32 callIndex, bytes memory dstCalldata) public {
    if (clampedTarget == address(_getAsset())) {
        callIndex %= 3;                                  // exactly 3 whitelisted functions
        if (callIndex == 0) {
            address to;
            uint256 value;
            assembly {
                to := mload(add(dstCalldata, 0x20))      // word 1 of the fuzzed bytes
                value := mload(add(dstCalldata, 0x40))   // word 2
            }
            dstCalldata = abi.encodeCall(MockERC20.mint, (to, value));
        }
        // callIndex 1 -> transfer(to, value), 2 -> transferFrom(from, to, value)
    }
    queue(clampedTarget, dstCalldata);
}

function performClampedCall() public updateGhostsWithType(OpType.CLAMPED_CALL) asActor {
    system.run(commands, state);
}
```

The three moves: `callIndex %= N` selects from a whitelist, `mload` slices argument words out of the uninterpreted fuzzed bytes, and `abi.encodeCall` re-encodes so the calldata is always well typed. Queue the command, then execute the whole queue in one handler so a sequence builds up across calls.

Add `shortcut_*` handlers that hardcode an entire known-interesting pipeline when the fuzzer still cannot assemble one. Reach for clamping only after a coverage report shows the code is unreached: unclamped handlers with array, struct, and enum parameters already constrain the fuzzer through the ABI.

## Generated handlers

`recon.json` maps Forge artifacts to the handlers to generate; `recon build` injects them between the `AUTO GENERATED` markers.

```json
{
  "out/YourSystem.sol/YourSystem.json": {
    "functions": [
      { "signature": "deposit(uint256)", "actor": "actor", "mode": "normal" },
      { "signature": "runWithState(tuple[],tuple)", "actor": "actor", "mode": "normal" }
    ],
    "separated": true
  }
}
```

`signature` uses `tuple` for struct and array parameters, `actor` chooses `asActor` or `asAdmin`, and `separated: true` emits one handler per function. Run `forge build` first, since the generator reads the artifacts. Everything absent from `recon.json` stays hand written.

## Verify the scaffold

```bash
forge build
forge test --match-contract CryticToFoundry -vv
```

The scaffold is ready when the replay harness compiles and its setup runs green. A tester that compiles but reverts in `setup()` burns an entire fuzzing campaign on a broken deployment, so confirm this before configuring any fuzzer.
