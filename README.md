# CrowdFund DApp

A decentralized crowdfunding protocol built in Solidity the smart contract infrastructure behind my personal Everest summit fundraise.

## The Real Use Case

In 2027 I'm attempting to summit Mount Everest. The goal is $69,000. No bank, no Kickstarter, no middleman the funds are held on-chain, contributors get auto-refunds if the summit fails, and milestone releases ensure accountability along the way.

This protocol is what makes that possible. It started as a single `Crowdfund.sol` for the EverestOrBust campaign. It grew into a full protocol suite with a factory, milestone-based fund releases, and contribution-weighted governance over fund disbursement.

[Follow the climb →](https://twitter.com/BhariGowda)

## Protocol

Three contracts, one purpose:

**CrowdFund.sol**  single campaign escrow. ETH or any ERC20 token. Auto-refund if the goal isn't met by the deadline. Used directly for the EverestOrBust campaign.

**EverestOrBust.sol** the actual campaign contract. USDC, USDT, and DAI. $69 cap per address. $69,000 goal. 69-day campaign (Jan 1 – Mar 10 2027). Auto-refund if goal not met. Pro-rata excess redemption if overfunded. No oracle needed — stablecoins only.

**CrowdFundFactory.sol**  CREATE2 deployer. Predictable addresses, per-creator campaign tracking, ETH and ERC20 variants.

**MilestoneCrowdFund.sol**  milestone-based fund release with contributor voting. The creator requests each milestone; contributors vote to approve or reject. Rejected milestones trigger a pro-rata refund of the remaining pool. Built for campaigns where accountability matters.

## Stack

- Solidity ^0.8.20 + Foundry
- React + TypeScript + Viem + Wagmi
- Ethereum mainnet + Sepolia testnet

## Tests

```bash
forge install
forge build
forge test
```

181 tests passing  unit, fuzz (1000 runs/property), and invariant (500,000 calls/invariant). Every custom error has an explicit revert test. Reentrancy guards verified by execution trace against malicious creator contracts.

## Stats

- 148 tests passing (unit, fuzz & invariant)
- 4 contracts: CrowdFund, CrowdFundFactory, MilestoneCrowdFund, EverestOrBust
- Full NatSpec documentation
- 81.61% branch coverage

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — design decisions and contract relationships
- [Audit](docs/AUDIT.md) — self-audit checklist and findings
- [Deployment Guide](docs/DEPLOYMENT.md) — step-by-step deployment instructions
- [Security Policy](SECURITY.md) — vulnerability disclosure process
- [Slither Findings](docs/SLITHER.md) — static analysis results and notes
- [Coverage Report](docs/COVERAGE.md) — per-contract test coverage breakdown

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, code standards, and PR process.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a full version history.
