# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | ✅        |

## Reporting a Vulnerability

Please report vulnerabilities to: security@crowdfund-dapp.eth

Do NOT open public issues for security bugs.

## Known Security Considerations

- All contracts use CEI (Checks-Effects-Interactions) pattern
- ReentrancyGuard on all state-changing functions
- Custom errors for gas efficiency
- No external price oracles (pure ETH/ERC20)

## Audit Status

Unaudited — use at your own risk.
