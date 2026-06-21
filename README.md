# CrowdFund DApp

Decentralized crowdfunding protocol built with Solidity + Foundry + React + Wagmi.

## Stack
- Solidity ^0.8.20
- Foundry (forge, cast)
- React + TypeScript
- Viem + Wagmi
- Deployed on Base

## Features
- Create campaigns with funding goals + deadlines
- Contribute ETH or any whitelisted ERC20 token
- Auto-refund if goal not met
- On-chain milestone releases

## Setup
```bash
forge install
forge build
forge test
```

## Stats
- 148 tests passing (unit, fuzz & invariant)
- 3 contracts: CrowdFund, CrowdFundFactory, MilestoneCrowdFund
- Full NatSpec documentation
- 81.61% branch coverage

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — design decisions and contract relationships
- [Audit](docs/AUDIT.md) — self-audit checklist and findings
- [Deployment Guide](docs/DEPLOYMENT.md) — step-by-step deployment instructions
- [Security Policy](SECURITY.md) — vulnerability disclosure process
- [Slither Findings](docs/SLITHER.md) — static analysis results and notes
- [Coverage Report](docs/COVERAGE.md) — per-contract test coverage breakdown
