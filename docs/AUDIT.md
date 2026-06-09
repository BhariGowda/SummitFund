# Security Audit Checklist

A thorough, code-grounded security checklist for the `crowdfund-dapp` contracts. Every
item below maps to a pattern that is actually present (or deliberately absent) in this
codebase, with pointers to where it lives. Use it as a pre-deployment gate and as a guide
for external reviewers.

> Status: **unaudited**. This document is a self-assessment checklist, not a substitute for
> an independent third-party audit. See [Residual Risks](#9-known-limitations--residual-risks).

---

## 1. Scope

| Contract | File | Role |
|---|---|---|
| `CrowdFund` | `src/CrowdFund.sol` | Single all-or-nothing campaign (ETH or ERC20). Creator withdraws on success; contributors refund on failure. |
| `CrowdFundFactory` | `src/CrowdFundFactory.sol` | CREATE2 deployer + per-creator index for `CrowdFund` campaigns. |
| `MilestoneCrowdFund` | `src/MilestoneCrowdFund.sol` | Campaign that releases escrow in contributor-governed milestones with pro-rata refund on rejection. |
| `IERC20` | `src/IERC20.sol` | Minimal interface (only `transfer`, `transferFrom`, `balanceOf`). |

**Out of scope / intentionally absent** (do not assume these exist):
- No proxy / upgradeability (no `delegatecall`, no storage-layout constraints).
- No owner/admin, no `Ownable`, no `Pausable`, no privileged backdoor.
- No price oracle, no external price feeds, no AMM interaction.
- No `SafeMath` library — relies on Solidity `^0.8.20` native checked arithmetic.
- Test-only mocks under `test/mocks/` are **not** production contracts and are excluded.

---

## 2. System Model & Trust Assumptions

**Actors**
- **Creator** — defines campaign terms at construction; can withdraw on success / drive milestones. Cannot change terms after deploy (all terms are `immutable` or set once).
- **Contributor** — sends ETH/tokens; gets refund on failure; votes on milestones (weighted by contribution).
- **Factory** — stateless deployer; holds no funds; cannot touch a deployed campaign's escrow.

**Trust assumptions**
- The creator is **not** trusted with contributor funds beyond the contract's rules. Funds are escrowed by the campaign contract, released only by the encoded conditions (goal reached, or milestone approved by weighted majority).
- The ERC20 token, if used, is assumed to be reasonably well-behaved. Known token-class caveats (fee-on-transfer, rebasing, ERC777 hooks) are addressed below where mitigated and flagged where not.
- `block.timestamp` is trusted to within typical miner tolerance (~seconds) for deadline checks only.

---

## 3. How to Use This Checklist

- `[ ]` = verify before mainnet deployment.
- Each section states the **pattern**, **where it lives**, and **how to verify** it.
- Re-run the full suite for every change: `forge test` (4 suites; ETH `CrowdFund`, `CrowdFundFactory`, `CrowdFundERC20`, `MilestoneCrowdFund`). The suite includes unit, edge-case, reentrancy, and fuzz tests.
- Recommended static/dynamic tooling before sign-off: `slither .`, `forge test --fuzz-runs 100000`, and an Echidna/Foundry invariant campaign on escrow conservation.

---

## 4. Core Security Patterns

### 4.1 Access Control
**Pattern:** Creator-only functions guard on `msg.sender != creator`, reverting `NotCreator`. `creator` is `immutable`, set once in the constructor and rejecting `address(0)` (`ZeroCreator`).

**Where:** `CrowdFund.withdraw`; `MilestoneCrowdFund.requestMilestone`, `claimMilestone`. Constructor `ZeroCreator` check in both.

- [ ] Every state-changing creator-only function checks `msg.sender == creator` **first**.
- [ ] `creator` is `immutable` and cannot be reassigned anywhere.
- [ ] No function lets a third party set/transfer `creator`.
- [ ] Voting and refund paths are permissionless by design (any contributor), and verified to key off `contributions[msg.sender]`, not on caller identity.
- [ ] Factory functions deploy campaigns owned by `msg.sender` only — no way to deploy a campaign owned by someone else.

### 4.2 Reentrancy — Guard + Checks-Effects-Interactions
**Pattern:** A `nonReentrant` modifier using a `uint256 _locked` flag (`1` = unlocked, `2` = locked) wraps every value-moving entrypoint. Independently, all such functions follow **Checks → Effects → Interactions**: storage is updated *before* the external ETH/token call.

**Where:**
- Guard: `CrowdFund.{contribute, contribute(uint256), withdraw, refund}`; `MilestoneCrowdFund.{contribute, contribute(uint256), claimMilestone, claimRefund, refund}`.
- CEI effects-before-interaction: `withdrawn = true` before payout (`CrowdFund.withdraw`); `contributions[msg.sender] = 0` before payout (`refund`); `status = Claimed; nextMilestone++` before payout (`claimMilestone`); `refundClaimed[msg.sender] = true` before payout (`claimRefund`).

**Note:** `requestMilestone` and `voteMilestone` make **no external calls** and are intentionally *not* `nonReentrant`.

- [ ] Every function that sends ETH or calls a token is `nonReentrant`.
- [ ] In every such function, all relevant storage writes happen **before** the external call.
- [ ] The guard restores `_locked = 1` after the call (no permanent lock on revert paths — Solidity reverts unwind it).
- [ ] A malicious recipient (ERC777 `tokensReceived`, or a contract `receive()`) re-entering a guarded function reverts. (Covered by `MilestoneCrowdFund` `test_Reentrancy_GuardBlocksReentrantClaim`, which proves a nested `claimMilestone` bubbles up as `TransferFailed`.)
- [ ] Cross-function reentrancy considered: e.g. re-entering `refund` from `withdraw` — blocked by the shared `_locked` flag (one guard per contract instance).

### 4.3 Pull-over-Push Refunds
**Pattern:** Refunds are **pull-based** — each contributor calls `refund()` / `claimRefund()` to withdraw their own share. The contract never loops over contributors to push funds, eliminating gas-griefing and one-bad-recipient-blocks-all failure modes.

**Where:** `CrowdFund.refund`, `MilestoneCrowdFund.refund`, `MilestoneCrowdFund.claimRefund`.

- [ ] No unbounded loop over contributors anywhere in a payout path.
- [ ] A single reverting recipient cannot block other contributors' refunds.
- [ ] Each refund is idempotency-guarded (see 4.4) so it cannot be drained twice.

### 4.4 Double-Action Guards / State Machine
**Pattern:** Every once-only action is gated by explicit state so it cannot repeat.

**Where:**
- `CrowdFund.withdrawn` (bool) → `AlreadyWithdrawn`.
- `CrowdFund.refund`: zeroes `contributions[msg.sender]` → second call hits `NothingToRefund`.
- `MilestoneCrowdFund` `Status` enum (`Pending → Active → Approved → Claimed`, or `→ Rejected`) gates `requestMilestone`/`voteMilestone`/`claimMilestone`.
- `hasVoted[index][voter]` → `AlreadyVoted` (one vote per contributor per milestone).
- `refundClaimed[account]` → `NothingToRefund` on repeat.
- `nextMilestone` enforces strict sequential ordering (`NotNextMilestone`).

- [ ] Withdraw can succeed at most once.
- [ ] A contributor can refund their balance at most once (ETH path zeroes balance; milestone path sets `refundClaimed`).
- [ ] A contributor can vote at most once per milestone.
- [ ] Milestones can only progress forward through the state machine; no state can be re-entered (e.g. an `Active` milestone cannot be re-requested → `MilestoneNotPending`).
- [ ] Milestones must be claimed in order; you cannot skip ahead.

### 4.5 ERC20 Safe-Transfer Handling
**Pattern:** Token moves go through low-level `call` helpers (`_safeTransfer`/`_safeTransferFrom` → `_callToken`) that tolerate non-compliant tokens which return **no data**, and revert (`TokenTransferFailed`) on a failed call **or** an explicit `false` return. This is the de-facto SafeERC20 semantics.

**Where:** `_callToken`, `_safeTransferToken`, `_safeTransferFrom` in both `CrowdFund` and `MilestoneCrowdFund`.

- [ ] Return value of every `transfer`/`transferFrom` is checked: `!ok || (ret.length != 0 && !decode(ret,bool))` reverts.
- [ ] Tokens that return no data on success (e.g. classic USDT-style) are accepted.
- [ ] Tokens that return `false` instead of reverting are treated as failures.
- [ ] No raw `IERC20(token).transfer(...)` call ignores the boolean result.

### 4.6 Fee-on-Transfer Accounting (inbound)
**Pattern:** On contribution, the contract credits the **measured balance delta**, not the requested amount: `received = balanceAfter - balanceBefore`, and reverts if `received == 0`. So fee-on-transfer / deflationary tokens are accounted correctly on the way **in**.

**Where:** `CrowdFund.contribute(uint256)`, `MilestoneCrowdFund.contribute(uint256)`. Tested by `test_FeeOnTransfer_CreditsReceivedAmount` and the `FeeOnTransferERC20` mock.

- [ ] Inbound credit is based on actual balance change, not the input argument.
- [ ] Zero net received reverts (`ZeroContribution`).
- [ ] ⚠️ **Outbound** payouts send the *recorded* amount; with a fee-on-transfer token the recipient receives slightly less than recorded (see 9). This is a known token-class limitation, not a contract bug.

### 4.7 ETH / ERC20 Mode Isolation
**Pattern:** A campaign is ETH-mode (`token == address(0)`) or token-mode, fixed at construction. The wrong entrypoint reverts: ETH `contribute()` on a token campaign → `NotEthCampaign`; token `contribute(uint256)` on an ETH campaign → `NotTokenCampaign`. ETH-mode payouts use `call`, token-mode payouts use the safe-transfer helpers, both routed through `_payout`/`_balance` which branch on `token == address(0)`.

**Where:** `contribute*`, `_payout`, `_balance` in both contracts.

- [ ] ETH cannot be deposited into a token campaign via `contribute()`.
- [ ] The contract has **no** `receive()`/`payable fallback` (except the explicitly-`payable` `contribute()`), so stray ETH cannot enter a token campaign through a normal send.
- [ ] Payout path matches campaign mode (ETH ↔ `call`, token ↔ safe transfer).

### 4.8 Token Validation
**Pattern:** A non-zero token must be a contract. The constructor rejects an EOA/empty token: `_token != address(0) && _token.code.length == 0` → `InvalidToken`. The factory's dedicated ERC20 entrypoint rejects `address(0)` → `TokenNotSupported`, so an intended-ERC20 campaign cannot silently fall back to ETH mode.

**Where:** `CrowdFund` constructor; `CrowdFundFactory.createCampaignERC20`.

- [ ] A token campaign cannot be constructed with an address that has no code.
- [ ] `createCampaignERC20` rejects the zero token.
- [ ] Note: a code-bearing but malicious token is **not** rejected here; mitigation relies on safe-transfer + reentrancy guard + CEI, not on a token whitelist.

### 4.9 Input & Constructor Validation
**Pattern:** All construction terms are validated up front and become immutable/fixed.

**Where:** constructors of all three contracts; factory re-validates before paying for deployment.

- [ ] `creator != address(0)` (`ZeroCreator`).
- [ ] `goal != 0` (`ZeroGoal`).
- [ ] `deadline > block.timestamp` (`DeadlineInPast`).
- [ ] `MilestoneCrowdFund`: `milestones.length > 0` (`NoMilestones`), each amount `> 0` (`ZeroMilestone`), `descriptions.length == milestones.length` (`MilestoneCountMismatch`), and `sum(milestones) == goal` (`MilestoneSumMismatch`).
- [ ] Factory validates `goal`/`deadline` before deployment so it fails cheaply.

### 4.10 Arithmetic Safety & Pro-Rata Rounding
**Pattern:** Solidity `^0.8.20` checked arithmetic guards all add/sub/mul (no `unchecked` blocks in value math). Pro-rata refunds compute `contributed * refundPool / totalRaised`; integer division can leave **dust** (≤ a few wei) in the contract — funds are conserved and never over-paid.

**Where:** `_record` (accumulation), `MilestoneCrowdFund.claimRefund` / `refundOwed`. Fuzzed by `testFuzz_ProRataRefundConserves` (asserts residual balance ≤ 1 wei) and `testFuzz_ApprovalThreshold`.

- [ ] No `unchecked` blocks around contribution/total/refund math.
- [ ] `mul` before `div` ordering in pro-rata to preserve precision.
- [ ] Rounding dust is bounded and only ever leaves residue *in* the contract (never overdraws).
- [ ] A contributor whose pro-rata share rounds to `0` reverts `NothingToRefund` rather than transferring zero.

### 4.11 Voting Integrity (MilestoneCrowdFund)
**Pattern:** Voting weight = a contributor's `contributions` balance. Funding **closes** once `totalRaised >= goal` (`FundingClosed`), so both `contributions` and `totalRaised` are frozen throughout the execution phase — tallies cannot be manipulated mid-vote. Thresholds: approve when `approveVotes * 2 > totalRaised` (strict majority of *all* contributed value); reject when `rejectVotes * 2 >= totalRaised` (point at which approval is unreachable). A milestone finalizes the instant a threshold is crossed.

**Where:** `voteMilestone`, `_checkFundingOpen`.

- [ ] Vote weight is read from frozen `contributions`; no new contributions can dilute/inflate weight after funding closes.
- [ ] `totalRaised` denominator is frozen during voting.
- [ ] Approval requires **strict** majority (exact 50% does not pass — `test_Vote_ExactHalfApproveIsNotEnough`).
- [ ] Rejection at ≥50% opposition is final and halts the campaign (`CampaignHalted` blocks further requests).
- [ ] A contributor cannot vote after the milestone finalized (`MilestoneNotActive`).
- [ ] ⚠️ A single contributor holding ≥50% weight can unilaterally approve or reject. This is **by design** (weighted governance), documented as a centralization consideration in (9).

### 4.12 CREATE2 Deterministic Deployment (Factory)
**Pattern:** Campaigns are deployed with CREATE2 using `salt = keccak256(creator, creatorCampaignCount)`. The address is predictable via `computeAddress` and unique per `(creator, index)`. The init-code hash binds all constructor args, so a predicted address only matches if deployed with identical terms.

**Where:** `_createCampaign`, `_computeAddress`, `_saltFor`, `_create2Address`.

- [ ] Salt is unique per creator per campaign index → no address collision between a creator's campaigns.
- [ ] `computeAddress` matches the actual deployed address (covered by `test_ComputeAddress_MatchesDeployment` and ERC20 variant).
- [ ] CREATE2 redeploy-to-same-address is impossible here because the salt's nonce (`_campaignsByCreator[creator].length`) strictly increases — no `selfdestruct` + redeploy metamorphic risk (contracts have no `selfdestruct`).
- [ ] Front-running a predicted address: an attacker cannot occupy a creator's predicted address because the salt is bound to that creator and the init-code hash to the exact terms; deploying with the same salt from the factory still records under `msg.sender`.

### 4.13 Custom Errors (Gas + Clarity)
**Pattern:** All reverts use custom errors rather than revert strings — cheaper and machine-parseable.

- [ ] No `require(..., "string")` in hot paths (all reverts are typed errors).
- [ ] Error names are specific enough for off-chain decoding and test assertions (`vm.expectRevert(X.selector)`).

---

## 5. Common-Vulnerability (SWC-style) Checklist

| # | Class | Status in this codebase |
|---|---|---|
| Reentrancy (SWC-107) | `nonReentrant` guard + CEI on all payout fns; tested | ✅ Mitigated |
| Access control (SWC-105/106) | `NotCreator` checks; `immutable creator`; no admin | ✅ Mitigated |
| Integer over/underflow (SWC-101) | Solidity ≥0.8 checked math; no `unchecked` | ✅ Mitigated |
| Unchecked external call return (SWC-104) | ETH `call` `ok` checked; token return decoded | ✅ Mitigated |
| Uninitialized storage / shadowing | Immutables + explicit init (`_locked = 1`) | ✅ N/A |
| `delegatecall`/proxy (SWC-112) | None used | ✅ N/A |
| `selfdestruct` (SWC-106) | None used | ✅ N/A |
| `tx.origin` auth (SWC-115) | Not used; `msg.sender` only | ✅ N/A |
| Timestamp dependence (SWC-116) | Only deadline boundary; ~seconds tolerance | ⚠️ Low |
| DoS via unbounded loop / push payment (SWC-113/128) | Pull payments; no loops over users | ✅ Mitigated |
| Front-running (SWC-114) | No price-sensitive ordering; CREATE2 salt creator-bound | ⚠️ See 4.12 |
| Weak randomness (SWC-120) | No randomness used | ✅ N/A |
| Signature replay (SWC-117/121) | No signatures used | ✅ N/A |
| Floating pragma (SWC-103) | `^0.8.20`; pin to `0.8.20` for production deploys | ⚠️ Pin on deploy |
| ERC20 non-standard behavior | Safe-transfer + balance-delta accounting | ✅ Mitigated (in); ⚠️ fee-on-transfer out |
| Force-fed ETH (`selfdestruct`/coinbase) | Accounting uses `contributions`/fixed amounts, not bare `balance` for credit | ✅ See 9 |

---

## 6. Per-Function Quick Checklist

**CrowdFund**
- [ ] `contribute()` — ETH-only, guarded, pre-deadline, non-zero, records before any call.
- [ ] `contribute(uint256)` — token-only, guarded, balance-delta credit, non-zero received.
- [ ] `withdraw()` — creator-only, goal reached, once-only, CEI, guarded.
- [ ] `refund()` — post-deadline, goal missed, per-contributor once, CEI, guarded.
- [ ] View helpers (`isERC20`, `goalReached`, `isActive`, `timeRemaining`) are pure reads with no side effects.

**CrowdFundFactory**
- [ ] `createCampaign` (ETH and token overloads) — validates, deploys via CREATE2, indexes under `msg.sender`.
- [ ] `createCampaignERC20` — rejects zero token, otherwise same path.
- [ ] `computeAddress` overloads — pure prediction, no state change.
- [ ] Enumeration views return stored arrays only.

**MilestoneCrowdFund**
- [ ] `contribute*` — as CrowdFund, plus `FundingClosed` once goal reached.
- [ ] `requestMilestone` — creator-only, goal reached, not halted, sequential, `Pending`→`Active`.
- [ ] `voteMilestone` — active milestone, contributor weight, one vote, threshold finalization.
- [ ] `claimMilestone` — creator-only, `Approved`→`Claimed`, advances `nextMilestone`, CEI, guarded.
- [ ] `claimRefund` — only after rejection, per-contributor once, pro-rata, CEI, guarded.
- [ ] `refund` — failed-funding path (post-deadline, goal missed), distinct from `claimRefund`.

---

## 7. Escrow-Conservation Invariants (suggested for `forge` invariant testing)

- [ ] **CrowdFund (ETH):** `address(this).balance == sum(contributions)` until `withdraw`/`refund`; after a successful `withdraw`, balance is 0 (plus any force-fed ETH, which goes to the creator since `withdraw` pays out `_balance()`).
- [ ] **CrowdFund (failure):** sum of refunds ≤ total contributed; no contributor refunds more than they put in.
- [ ] **Milestone:** `sum(claimed milestone amounts) + remaining escrow == totalRaised` (ignoring force-fed ETH and rounding dust).
- [ ] **Milestone (rejection):** `sum(pro-rata refunds) ≤ refundPool`; residue ≤ rounding dust.
- [ ] **No path** lets total outflow exceed total inflow for any contributor or for the contract.

---

## 8. Testing & Tooling Gate

- [ ] `forge test` passes (unit + edge + reentrancy + fuzz across all 4 suites).
- [ ] Fuzz tests run with elevated runs before release: `forge test --fuzz-runs 100000`.
- [ ] `forge coverage` reviewed — every revert branch exercised.
- [ ] `slither .` reviewed; triage every finding (expect informational on low-level calls — intentional).
- [ ] Optional: Echidna / Foundry invariant run on the conservation invariants in §7.
- [ ] Compiler pinned to a single version for production (`solc_version = "0.8.20"` in `foundry.toml`), optimizer settings recorded for verification.

---

## 9. Known Limitations & Residual Risks

These are **acknowledged**, not silently ignored. A reviewer/deployer must accept them.

1. **Creator stalling (liveness).** After the goal is reached, `MilestoneCrowdFund` has **no deadline** on the execution phase. If the creator never calls `requestMilestone`, contributor funds remain escrowed indefinitely with no built-in timeout/rescue. Contributors only get a refund path if a milestone is *requested and then rejected*. Consider adding an execution-phase deadline or an inactivity-triggered refund before relying on this in production.
2. **Fee-on-transfer / rebasing tokens (outbound & balance drift).** Inbound contributions are credited by balance delta (safe). But milestone payouts send a *fixed recorded amount*; a fee-on-transfer token delivers slightly less to the creator, and rebasing tokens can desync `totalRaised` from actual balance. Prefer standard, non-rebasing ERC20s.
3. **Weighted-governance centralization.** Any contributor with ≥50% of contributed value can unilaterally approve every milestone or reject (halting the campaign). This is intentional but is a centralization/whale risk in low-participation campaigns.
4. **Timestamp tolerance.** Deadline checks rely on `block.timestamp`; a miner/validator can nudge it by a few seconds around the boundary. Impact is limited to last-second contribution/refund eligibility — no value can be stolen.
5. **Force-fed ETH.** ETH can be force-sent via `selfdestruct`/coinbase to any contract. Accounting never credits force-fed ETH (contributions are tracked explicitly), so it cannot inflate `totalRaised`, votes, or refund shares. In `CrowdFund` a successful `withdraw` forwards the entire `_balance()` (so force-fed ETH goes to the creator, not stuck). In `MilestoneCrowdFund`, force-fed ETH may remain as un-claimable dust after all milestones; it does not affect correctness.
6. **Malicious token contracts.** A code-bearing token is not whitelisted. Defense rests on `nonReentrant` + CEI + checked transfer returns. A pathological token (e.g. one that reverts selectively or returns lies) can grief its own campaign but cannot drain ETH from other campaigns (campaigns are isolated instances).
7. **Floating pragma.** Source uses `^0.8.20`. Pin to an exact version at deploy time and record it for source verification.
8. **Unaudited.** No external audit has been performed. Treat as experimental.

---

## 10. Pre-Deployment Sign-Off

| Item | Owner | Status |
|---|---|---|
| All §4 patterns verified in code | | ☐ |
| §5 vulnerability checklist triaged | | ☐ |
| §6 per-function checklist complete | | ☐ |
| §7 invariants run (Foundry/Echidna) | | ☐ |
| §8 tooling gate passed (`forge test`, `slither`, fuzz) | | ☐ |
| §9 residual risks reviewed & accepted | | ☐ |
| Compiler version pinned & recorded | | ☐ |
| Constructor terms double-checked (creator/goal/deadline/milestones) | | ☐ |
| External audit commissioned (recommended before mainnet value) | | ☐ |

---

*Related: [`docs/SECURITY.md`](./SECURITY.md) (summary) and [`/SECURITY.md`](../SECURITY.md) (disclosure policy).*
