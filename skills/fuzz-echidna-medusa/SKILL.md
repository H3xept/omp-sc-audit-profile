---
name: fuzz-echidna-medusa
description: Write and run stateful fuzzing campaigns with Echidna and Medusa against a Chimera/Recon tester. Use when adding invariant or property checks, writing echidna.yaml or medusa.json, starting or resuming a fuzz campaign, chasing low coverage, or turning a failing call sequence into a Foundry reproducer. Triggers on echidna, medusa, fuzz campaign, corpus, assertion mode, property mode, invariant_, failing sequence, shrink, trophy.
---

# Echidna and Medusa campaigns

One tester contract, two fuzzers, one Foundry replay. Everything below assumes that tester exists; when it does not, build it first with `skill://recon-suite`.

Both fuzzers call **every public function** on the target, so a check is anything that reverts on a broken state. The prefixes below are routing conventions, not the gate.

## Preflight

Confirm each item before writing config. A missing item wastes a campaign.

| Check | Command | Expected |
| --- | --- | --- |
| Tester compiles | `forge build` | success |
| Replay harness runs | `forge test --match-contract CryticToFoundry -vv` | green |
| Fuzzers installed | `which echidna medusa` | both paths |
| crytic-compile sees the project | `crytic-compile . --foundry-compile-all` | artifacts, no solc error |

`forge build` passing while `crytic-compile` fails means the fuzzers will fail too: fix the compile bridge (see [Library linking](#library-linking)) before anything else.

## Prefix routing

| Function on the tester | Echidna (`testMode: assertion`) | Medusa | Foundry |
| --- | --- | --- | --- |
| target handler, e.g. `vault_deposit(uint256)` | called, asserts checked | called, asserts checked | callable |
| `invariant_*` | called as an ordinary public function | runs after **every** transaction via `propertyTesting.testPrefixes` | callable |
| `property_*` | called as an ordinary public function | called as an ordinary public function | callable |
| `echidna_*` returning `bool` | property mode only | ignored | callable |
| `optimize_*` | ignored | maximizes the return value when `optimizationTesting.enabled` | callable |

Consequences worth internalizing:

- `invariant_*` is the strongest placement: Medusa checks it after every call, Echidna checks it whenever it happens to call it. Put global truths there.
- `property_*` and target handlers are checked only when called, so a property that must hold continuously belongs in `invariant_*`.
- Asserting through Chimera's `Asserts` (`eq`, `gte`, `lte`, `t`) keeps one body working under all three runners, because `CryticAsserts` and `FoundryAsserts` bind the same calls to each runner's failure mechanism.

## Writing checks that catch real bugs

Four check shapes carry nearly all value. Each one states a truth about the system, never a restatement of the implementation.

**Global invariant** — holds after every call, reads only public state:

```solidity
// Properties.sol
function invariant_solvency() public {
    gte(asset.balanceOf(address(vault)), vault.totalAssets(), "vault undercollateralized");
}
```

**Canary invariant** — seed unreachable state in `setup()`, then assert it stayed untouched. This catches memory, storage, and encoding corruption that no hand-written property predicts:

```solidity
// Setup.sol — poison every slot the protocol must never write
bytes constant DIRTY_FLAG = hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
for (uint256 i = FIRST_UNUSED_SLOT; i < SLOT_COUNT; i++) {
    system.debugWriteSlot(i, DIRTY_FLAG);
}

// Properties.sol
function invariant_unused_slots_untouched() public {
    for (uint256 i = FIRST_UNUSED_SLOT; i < SLOT_COUNT; i++) {
        bytes memory slot = system.readSlot(i);
        eq(slot.length, DIRTY_FLAG.length, "sentinel length changed");
        eq(uint256(keccak256(slot)), uint256(keccak256(DIRTY_FLAG)), "sentinel value changed");
    }
}
```

**Transition property** — compares the `_before` / `_after` ghosts captured by the `updateGhosts` modifier, so it can assert about a single call rather than a state:

```solidity
// Properties.sol
function property_shares_monotonic() public {
    if (currentOperation == OpType.DEPOSIT) {
        gte(_after.totalShares, _before.totalShares, "deposit burned shares");
    }
}
```

**Doomsday handler** — a target function asserting that a critical operation can never revert. Wrap the call in `try/catch` and fail in the catch:

```solidity
// targets/DoomsdayTargets.sol
function doomsday_withdraw_never_reverts(uint256 amount) public asActor {
    try vault.withdraw(amount) {
    } catch {
        t(false, "withdraw reverted for a solvent actor");
    }
}
```

The bar for keeping a check: name the bug that makes it fail. A check that can only fail when the fuzzer is misconfigured is noise.

## echidna.yaml

```yaml
testMode: assertion          # every public function is a check; property mode needs bool-returning echidna_*
prefix: echidna_             # property-mode name filter; harmless under assertion mode
coverage: true               # writes coverage maps into corpusDir; the only way to see reach
corpusDir: echidna           # persisted corpus, reused and grown on every run
balanceAddr: 300000000000000000000       # 300 ETH per sender, enables payable paths
balanceContract: 300000000000000000000   # 300 ETH to the tester, needs a payable constructor
filterFunctions: []          # empty = fuzz everything; add names only to prune noise
deployer: "0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496"
contractAddr: "0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496"
shrinkLimit: 100000          # shrink attempts per failure; lower to ~5000 for fast iteration
cryticArgs: ["--foundry-compile-all"]
```

`deployer` and `contractAddr` pin to the same well-known address that Medusa's `deployerAddress` uses, so a failing sequence reproduces byte-for-byte across Echidna, Medusa, and Forge. Keep all three equal.

Run:

```bash
echidna . --contract CryticTester --config echidna.yaml --format text --workers 16 --test-limit 1000000
```

## medusa.json

```json
{
  "fuzzing": {
    "workers": 40,
    "workerResetLimit": 50,
    "timeout": 0,
    "testLimit": 0,
    "callSequenceLength": 100,
    "corpusDirectory": "medusa",
    "coverageEnabled": true,
    "deploymentOrder": ["CryticTester"],
    "targetContracts": ["CryticTester"],
    "targetContractsBalances": ["0x27b46536c66c8e3000000"],
    "constructorArgs": {},
    "deployerAddress": "0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496",
    "senderAddresses": ["0x10000", "0x20000", "0x30000"],
    "blockNumberDelayMax": 60480,
    "blockTimestampDelayMax": 604800,
    "blockGasLimit": 125000000,
    "transactionGasLimit": 12500000,
    "testing": {
      "stopOnFailedTest": false,
      "stopOnFailedContractMatching": false,
      "stopOnNoTests": true,
      "testAllContracts": false,
      "traceAll": false,
      "assertionTesting": {
        "enabled": true,
        "testViewMethods": true,
        "panicCodeConfig": { "failOnCompilerInsertedPanic": false, "failOnAssertion": true }
      },
      "propertyTesting": { "enabled": true, "testPrefixes": ["invariant_"] },
      "optimizationTesting": { "enabled": false, "testPrefixes": ["optimize_"] }
    },
    "chainConfig": {
      "codeSizeCheckDisabled": true,
      "cheatCodes": { "cheatCodesEnabled": true, "enableFFI": false }
    }
  },
  "compilation": {
    "platform": "crytic-compile",
    "platformConfig": { "target": ".", "solcVersion": "", "exportDirectory": "", "args": ["--foundry-compile-all"] }
  },
  "logging": { "level": "info", "logDirectory": "" }
}
```

Keys that change outcomes, not just speed:

- `workers` — one per physical core. `workerResetLimit: 50` resets a worker to the post-deployment snapshot every 50 transactions, bounding memory; raise it when `setup()` is expensive.
- `timeout: 0` / `testLimit: 0` — unlimited, run until interrupted. Set a finite `testLimit` for a CI or smoke run.
- `callSequenceLength` — how deep a state machine the fuzzer can build. Deep sequences find more and shrink slower.
- `stopOnNoTests: true` — hard-fails when zero testable functions are found, which is how a mis-named `targetContracts` surfaces in seconds instead of hours.
- `testAllContracts: false` — fuzz only the tester; mocks would otherwise drown the real target.
- `traceAll: false` — trace only failures. Flip it on solely while debugging coverage.
- `testViewMethods: true` — calls view and pure functions too, which is free coverage on getters.
- `blockNumberDelayMax` / `blockTimestampDelayMax` — allow ~60k blocks and 7 days of jumping between calls; required for vesting, deadlines, and rate accrual. Set both to 0 to forbid time travel.
- `codeSizeCheckDisabled: true` — the tester compiles the whole system plus mocks and ghosts into one contract, so it exceeds the EIP-170 limit.
- `panicCodeConfig` — `failOnAssertion` is the one flag that is always right. Enable a specific panic flag (`failOnArithmeticUnderflow`, `failOnDivideByZero`, `failOnOutOfBoundsArrayAccess`, and so on) only when the target genuinely must never reach it; with fully fuzzed inputs those panics are usually domain behavior, and enabling them buries real findings under noise.

Run:

```bash
medusa fuzz                                     # reads medusa.json from cwd
medusa fuzz --target-contracts CryticTester     # override the target without editing config
```

## Library linking

A contract that calls a library at a fixed address needs the library both linked at compile time and deployed at run time, at the **same** address, in **both** tool configs. Getting one of the four places wrong produces an empty-code call that looks like a logic bug.

```yaml
# echidna.yaml
cryticArgs: ["--compile-libraries=(MathLib,0xf01)", "--foundry-compile-all"]
deployContracts: [["0xf01", "MathLib"]]
```

```json
// medusa.json — same pair, split into separate argv elements
"args": ["--compile-libraries", "(MathLib,0xf01)", "--foundry-compile-all"]
```

`--foundry-compile-all` is what makes both fuzzers build through Foundry, so `via_ir`, the optimizer, remappings, and submodule pins all apply identically to the fuzzers and to `forge test`. Mirror the Foundry compiler settings into `solc.json` as well, because tools that build outside Foundry read that file:

```json
{ "optimizer": { "enabled": true, "runs": 10000 }, "viaIR": true }
```

Add `echidna/`, `medusa/`, and `crytic-export/` to `.gitignore`.

## Campaign discipline

Run campaigns as supervised background processes, not foreground commands: `hub` `op: "start"` with the command, then `hub` `op: "logs"` to follow. An unlimited campaign never returns on its own.

1. **Smoke run first.** `medusa fuzz` with a finite `testLimit` (around 5000) and confirm the tool reports the expected number of tests. Zero tests means a config error; a failure in the first thousand calls usually means a broken `setup()`, not a protocol bug.
2. **Check reach before trusting a clean run.** A green campaign over unreached code proves nothing. Read the coverage report in the corpus directory, list the target functions with no hits, and fix reach — usually with clamped handlers (`skill://recon-suite`) — before extending the run.
3. **Let the corpus grow.** Both tools reuse and extend the corpus directory across runs. Delete it only when the tester's ABI changes, since stale sequences then decode into different calls.
4. **Keep failures running.** `stopOnFailedTest: false` collects several distinct failures per campaign instead of one.

## Triage a failure into a reproducer

The output of a campaign is a call sequence. The deliverable is a Foundry test.

1. **Shrink.** Echidna shrinks automatically within `shrinkLimit`. For Medusa, re-run with `traceAll: true` on the saved sequence to get the full trace.
2. **Transcribe.** Write the shrunk calls into the replay harness, which already inherits the same `TargetFunctions` tree, so every handler and ghost is available:

   ```solidity
   // CryticToFoundry.sol
   function test_repro_solvency_break() public {
       vault_deposit(1);
       vault_withdraw(type(uint88).max);
       invariant_solvency();
   }
   ```

   ```bash
   forge test --match-contract CryticToFoundry --match-test test_repro_solvency_break -vvvv
   ```
3. **Confirm the failure is the fuzzer's failure.** Same assertion, same message. A reproducer that fails for a different reason is a second bug and a separate finding.
4. **Promote to a trophy.** Move the confirmed reproducer into a permanent `Trophies` contract with a back-link to the issue, so the fix keeps a regression test:

   ```solidity
   // test/Trophies.sol — forge test --match-contract Trophies -vv
   contract Trophies is SpecTestBase {
       // Dynamic array element pointer base off by 0x20
       // https://github.com/org/repo/issues/35
       function test_dynamic_array_pointer_base() public pure { /* ... */ }
   }
   ```
5. **Re-run the campaign after the fix.** The corpus already holds the failing sequence, so the fuzzer reaches it again within seconds and confirms the fix.

A finding is done when the trophy fails on the old code and passes on the new code.

## Where fuzzing stops

Path-explosive components — bespoke encoders, stack machines, deep nested containers — resist a solver but reward a long fuzz campaign; the reverse holds for dispatch tables and packing layers, where a bounded symbolic proof is exhaustive and cheap. Prove those with `skill://halmos-verify`, and record which properties you deferred to fuzzing in a property matrix so the gap is visible rather than forgotten.
