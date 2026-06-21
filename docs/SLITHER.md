# Slither Static Analysis

Run with:
```bash
slither . --config-file slither.config.json
```

101 detectors run across 4 contracts, 29 results. Findings worth tracking:

## Real Findings

### `arbitrary-send-eth` in `_safeTransfer()`
**Files:** `CrowdFund.sol`, `MilestoneCrowdFund.sol`
Both contracts send ETH to an address derived from contract state (`creator`, or a contributor during refund), not directly from user input. Slither flags any low-level `.call{value}()` regardless of how the recipient was determined. Verified safe: the recipient is always either the validated `creator` (set once in the constructor) or `msg.sender` during a refund — never an arbitrary caller-supplied address.

### `reentrancy-balance` / `reentrancy-no-eth` in `contribute(uint256)`
**Files:** `CrowdFund.sol`, `MilestoneCrowdFund.sol`
The ERC20 `contribute()` path reads the token balance before calling `_safeTransferFrom()`, then computes `received` from the balance delta to support fee-on-transfer tokens. State (`contributions`, `totalRaised`) is written after this external call. This is a deliberate design choice — supporting fee-on-transfer tokens requires measuring the actual received amount, which can only happen after the transfer completes. The `nonReentrant` guard on `contribute()` covers the actual reentrancy risk; this pattern is the standard way fee-on-transfer-tolerant contracts are written.

### `incorrect-equality` (`received == 0`, `weight == 0`)
**Files:** `CrowdFund.sol`, `MilestoneCrowdFund.sol`
Strict equality checks against zero are flagged generically by Slither for any comparison that could theoretically be bypassed by manipulating the compared value to a non-zero dust amount. Here, `received` and `weight` are computed internally (balance deltas, contribution-weighted vote totals) and aren't directly attacker-controlled in a way that defeats the zero-check's purpose — they correctly catch genuine zero-value edge cases (e.g. an all-fee token leaving nothing after transfer).

### `uninitialized-local` (`sum` in `MilestoneCrowdFund` constructor)
**File:** `MilestoneCrowdFund.sol`
`sum` is declared and used as an accumulator in a loop validating that milestone amounts add up to the campaign goal. Solidity default-initializes local `uint256` to zero, so this is functionally correct — Slither flags any local variable lacking an explicit initializer regardless of whether the default value is the intended starting state.

### `missing-zero-check` on `_token` in `MilestoneCrowdFund` constructor
**File:** `MilestoneCrowdFund.sol`
`_token` is stored without an explicit zero-address check. `address(0)` is actually the valid sentinel for "this is an ETH campaign" throughout both contracts (checked via `token != address(0)` at each entry point), so a zero check here would break legitimate ETH-campaign creation. This is intentional design, not an oversight.

### `low-level-calls`
**Files:** `CrowdFund.sol`, `MilestoneCrowdFund.sol`
Both contracts use `.call()` for ETH transfers (avoiding the 2300 gas stipend limit of `.transfer()`) and for ERC20 token calls (to tolerate non-standard tokens that don't return a bool). Both patterns are deliberate and validated with explicit success checks (`TransferFailed`, `TokenTransferFailed`).

### `too-many-digits` in `_computeAddress()`
**File:** `CrowdFundFactory.sol`
Flags the long `keccak256` hash literal used in CREATE2 address computation. This is inherent to how CREATE2 address derivation works — not a real issue.

## Notes

- `timestamp` detector results (deadline comparisons) are expected throughout both contracts and are not flagged as real findings — the same caveat applies as documented in KaliMaga's Slither report.
- `solc-version` flags the `^0.8.20` floating pragma against a list of historical compiler issues unrelated to this codebase's actual usage patterns.

## Action Items

None of the above require code changes. All flagged patterns are either intentional design decisions (fee-on-transfer support, zero-address sentinel for ETH campaigns, low-level calls for gas/compatibility reasons) or generic heuristics that don't apply to this codebase's specific data flow.
