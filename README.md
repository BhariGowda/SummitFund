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
- 146 tests passing (unit, fuzz & invariant)
- 3 contracts: CrowdFund, CrowdFundFactory, MilestoneCrowdFund
- Full NatSpec documentation
- Slither static analysis configured
