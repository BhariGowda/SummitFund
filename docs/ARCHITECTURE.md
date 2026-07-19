# Architecture

## Contracts

- **CrowdFund.sol** — single campaign escrow (ETH or ERC20). All-or-nothing: creator withdraws on success, contributors refund on failure.
- **CrowdFundFactory.sol** — CREATE2 deployer with predictable addresses and per-creator campaign tracking.
- **MilestoneCrowdFund.sol** — milestone-based fund release with contribution-weighted voting. Rejected milestones trigger pro-rata refunds.
- **EverestOrBust.sol** — the actual Everest 2027 fundraise contract. Multi-stablecoin (USDC/USDT/DAI), $6.9 per-address cap, $69,000 goal (10,000 contributors), 69-day campaign starting Dec 10 2026. No price oracle — stablecoins only. Contributions close automatically once the goal is reached — no overfunding, no excess redemption needed.

## Design Patterns

- **CEI (Checks-Effects-Interactions)** — all state changes happen before external calls
- **Pull-over-push refunds** — contributors call `refund()` themselves; no loops, no push failures
- **Custom errors** — gas-efficient reverts with descriptive selectors
- **Inline reentrancy guard** — no external dependencies, same pattern across all contracts
- **Normalized accounting** — EverestOrBust scales 6-decimal tokens (USDC/USDT) to 18 decimals internally for consistent cap and goal arithmetic

## Networks

Ethereum mainnet + Sepolia testnet only. No L2s — EverestOrBust holds real money and ETH mainnet has the strongest uptime guarantee of any EVM chain.
