# Contributing Guide

Thank you for considering contributing to the **FlockTrade** project! This document provides guidelines and instructions for contributing.

## Code of Conduct

This project and everyone who participates in it is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## How to Contribute

### Reporting Bugs

Before creating bug reports, check the issues list as you may find that you don't need to create one. When creating a bug report, include as much detail as possible:

- **Use a clear and descriptive title**
- **Describe the exact steps that reproduce the problem**
- **Provide specific examples to demonstrate the steps**
- **Describe the behavior you observed after following the steps**
- **Explain what behavior you expected to see and why**
- **Include screenshots and animated GIFs if possible**
- **Include your configuration**: MetaTrader version, symbol, timeframe, etc.

### Suggestions for Improvements

Improvement suggestions are always welcome. When creating an improvement suggestion, include:

- **Use a clear and descriptive title**
- **Provide a step-by-step description of the suggestion**
- **Provide specific examples to demonstrate the steps**
- **Describe the current behavior and the expected behavior**
- **Explain why this improvement would be useful**

### Pull Requests

- Fill out the pull request template completely
- Follow MQL5 coding styles
- Write clear and descriptive commit messages
- Include tests when appropriate
- Update documentation as needed

## Development Process

1. **Fork** the repository
2. **Clone** your fork locally
3. **Create a branch** for your feature (`git checkout -b feature/AmazingFeature`)
4. **Make your commits** (`git commit -m 'Add some AmazingFeature'`)
5. **Push** to the branch (`git push origin feature/AmazingFeature`)
6. **Open a Pull Request** describing your changes

## Coding Conventions

### MQL5

- Use **camelCase** for variables and functions
- Use **UPPER_CASE** for constants
- Add descriptive comments for complex logic
- Maintain MQL5 compatibility
- Test in backtest environment before submitting

### Commit Messages

- Use the imperative ("Add feature" not "Added feature")
- Limit the first line to 72 characters
- Reference issues and pull requests liberally after the first line
- Consider using emojis:
  - 🎨 `:art:` - Structural/formatting improvement
  - 🐛 `:bug:` - Bug fix
  - ✨ `:sparkles:` - New feature
  - 📝 `:memo:` - Documentation
  - 🧪 `:test_tube:` - Tests
  - ⚡ `:zap:` - Performance improvement
  - 🔒 `:lock:` - Security fix

## Project Structure

```
flocktrade/
├── src/                    # MQL5 source code
│   ├── MarketRegime.mq5
│   ├── StatisticalEdge.mq5
│   └── ...
├── docs/                   # Documentation
├── tests/                  # Tests
└── README.md
```

## Reporting Vulnerabilities

**Please do not open public issues for security vulnerabilities.** See [SECURITY.md](SECURITY.md) for responsible disclosure instructions.

## Pull Request Review

- All pull requests will be reviewed before being merged
- Constructive feedback will be provided
- Changes may be requested
- Once approved, it will be merged by the maintainer

## Questions?

Feel free to open an issue with the `question` tag or contact us through community channels.

## Thank You

We thank all contributors who help improve this project!
