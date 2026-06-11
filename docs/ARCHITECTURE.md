# Architecture

## Contracts
- **CrowdFund.sol** — single campaign escrow (ETH + ERC20)
- **CrowdFundFactory.sol** — CREATE2 deployer, predictable addresses
- **MilestoneCrowdFund.sol** — milestone-based releases with voting

## Design Patterns
- CEI (Checks-Effects-Interactions)
- Custom errors for gas efficiency
- Pull-over-push for refunds
