# Deployment Guide

## Networks

- Ethereum Mainnet: `forge script script/Deploy.s.sol --rpc-url mainnet --broadcast --verify`
- Sepolia Testnet: `forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify`

## Requirements

- Foundry installed
- `.env` with `PRIVATE_KEY` and `ETHERSCAN_API_KEY`
- RPC URLs set in `.env` (`ETH_RPC_URL`, `SEPOLIA_RPC_URL`)

## Deployed Contracts

| Network | CrowdFundFactory | EverestOrBust | Date |
|---------|-----------------|---------------|------|
| Sepolia Testnet | TBD | TBD | TBD |
| Ethereum Mainnet | TBD | TBD | TBD |

## Deploy Factory

```bash
source .env
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify
```

## Deploy EverestOrBust Campaign

After deploying the factory, set `FACTORY_ADDRESS` in `.env` then:

```bash
forge script script/DeployEverestOrBust.s.sol --rpc-url sepolia --broadcast --verify
```

## EverestOrBust Campaign Parameters

| Parameter | Value |
|---|---|
| Start | Dec 10 2026 00:00:00 UTC (`1765324800`) |
| End | Feb 17 2027 00:00:00 UTC (start + 69 days) |
| Goal | $69,000 (69_000e18 normalized) |
| Cap per address | $6.9 (6.9e18 normalized) |
| Contributors needed | 10,000 |
| Tokens | USDC, USDT, DAI |
| Network | Ethereum mainnet only |

## Sepolia Token Addresses

| Token | Address |
|-------|---------|
| USDC  | 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 |
| USDT  | 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0 |
| DAI   | 0x68194a729C2450ad26072b3D33ADaCbcef39D574 |

## Mainnet Token Addresses

| Token | Address |
|-------|---------|
| USDC  | 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 |
| USDT  | 0xdAC17F958D2ee523a2206206994597C13D831ec7 |
| DAI   | 0x6B175474E89094C44Da98b954EedeAC495271d0F |
