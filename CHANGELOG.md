# Changelog

## [1.5.0] - 2026-07-05
### Changed
- `EverestOrBust.sol` — contribution cap reduced from $69 to $6.9 per address
  - Goal stays $69,000 — now requires 10,000 contributors instead of 1,000
  - Truly community-funded: $6.9 is accessible to anyone, anywhere
  - Campaign dates updated: Dec 10 2026 – Feb 17 2027 (69 days)
  - All 39 tests updated and passing with new parameters
- `foundry.toml` — increased gas limit for 10k-contributor test loops

## [1.4.0] - 2026-06-27
### Added
- `EverestOrBust.sol` — the actual Everest summit 2027 fundraise contract
  - Accepts USDC, USDT, and DAI (stablecoins only, no oracle needed)
  - $69 per-address contribution cap enforced on-chain
  - $69,000 goal, 69-day campaign (Jan 1 – Mar 10 2027)
  - Auto-refund if goal not met by deadline
  - Pro-rata excess redemption if campaign is overfunded
  - Inline reentrancy guard (no external dependencies)
- `script/DeployEverestOrBust.s.sol` — deploy script for Ethereum mainnet and Sepolia testnet
- 33 tests covering all revert paths including a real reentrancy attack via malicious token

## [1.3.0] - 2026-06-20
### Added
- Explicit reentrancy guard test for `CrowdFund.withdraw()` via a malicious creator contract, verified by execution trace
- `TokenTransferFailed` revert test for `MilestoneCrowdFund.contribute()`

### Fixed
- `lib/forge-std` registered as a proper git submodule (was a plain directory dump causing CI failures on a fresh clone)
- GitHub Actions CI workflow added, running the full test suite on every push and PR

### Changed
- Branch coverage: 80.23% -> 81.61% (148 tests passing)

## [1.2.0] - 2026-06-17
### Changed
- Fuzz runs increased to 1000
- Gas snapshot added
- README updated with accurate test count

## [1.1.0] - 2026-06-10
### Added
- ERC20 token support
- MilestoneCrowdFund.sol - milestone-based fund releases
- 139 tests passing
- Security audit checklist (docs/AUDIT.md)
- Deployment guide (docs/DEPLOYMENT.md)

## [1.0.0] - 2026-06-08
### Added
- CrowdFund.sol - ETH crowdfunding with escrow
- CrowdFundFactory.sol - CREATE2 deployer
- 44 tests passing
## June 2026 Update
- 146 tests passing (unit, fuzz, invariant)
- Full security tooling (Slither, GitHub Actions CI)
- Deployment pending (Sepolia testnet first, then Ethereum mainnet)
