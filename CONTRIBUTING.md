# Contributing

CrowdFund DApp is a portfolio project but contributions, issues, and security findings are welcome.

## Development Setup

```bash
git clone https://github.com/BhariGowda/crowdfund-dapp.git
cd crowdfund-dapp
forge install
forge build
forge test
```

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.

## Running Tests

```bash
# Full suite
forge test

# With higher fuzz runs
forge test --fuzz-runs 5000

# Specific contract
forge test --match-contract MilestoneCrowdFundTest

# Coverage report
forge coverage --report summary --ir-minimum

# Gas snapshot diff
forge snapshot --diff
```

## Code Standards

- Solidity ^0.8.20
- Full NatSpec on every public and external function
- Custom errors over `require` strings
- `nonReentrant` on all state-changing external functions
- Checks-effects-interactions pattern enforced throughout
- `forge fmt` for formatting before committing

## Test Standards

- Every new function needs at least one happy-path test and one revert test per custom error
- Fuzz tests for any amount-based or math-heavy logic
- Reentrancy guards must be tested with an actual attacker contract, verified via execution trace
- Run `forge coverage --ir-minimum` and document any branch coverage gaps honestly in `docs/COVERAGE.md`

## Pull Request Process

1. Fork the repo
2. Create a feature branch (`git checkout -b feat/your-feature`)
3. Write tests first, then implementation
4. Ensure `forge test` passes and `forge snapshot --diff` shows no unexpected gas regressions
5. Open a PR with a clear description of what changed and why

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting guidelines. Do not open public issues for potential vulnerabilities.
