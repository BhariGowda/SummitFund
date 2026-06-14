# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | ✅        |

## Reporting a Vulnerability

Please report vulnerabilities privately to: security@crowdfund-dapp.eth

Do NOT open public GitHub issues for security bugs.

Response SLA:
- Acknowledgement: 48 hours
- Triage: 7 days
- Fix: 30 days

## Security Considerations

- All contracts use CEI (Checks-Effects-Interactions) pattern
- Reentrancy guards on all state-changing functions
- Custom errors for gas efficiency
- No external price oracles
- Pull-over-push for all fund movements
- Contribution-weighted voting prevents whale attacks on milestones

## Audit Status

Unaudited. Use at your own risk. Not recommended for mainnet use without professional audit.
