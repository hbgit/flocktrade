# Security Policy

## Reporting Vulnerabilities

Security is very important to us. If you discover a security vulnerability, **please do not disclose it publicly**. Instead, follow this responsible disclosure process.

### How to Report

1. **Send an email** to the security team with:
   - Detailed description of the vulnerability
   - Steps to reproduce the issue
   - Potential impact and severity
   - Your contact information

2. **Do not publish** the vulnerability on:
   - Public GitHub issues
   - Public forums
   - Social media
   - Before we respond

### Response Process

1. We will receive your report within 48 business hours
2. We will investigate and assess the vulnerability
3. We will prepare a fix
4. You will be updated on the progress
5. We will publish a security advisory when appropriate
6. The fix will be released

## Types of Vulnerabilities

We consider the following as security vulnerabilities:

- **Authentication Failures** - Bypass of security mechanisms
- **Code Injection** - Unauthorized code execution
- **Data Manipulation** - Unauthorized access or modification
- **Information Leakage** - Exposure of sensitive data
- **Validation Failures** - Unsafe input processing
- **Configuration Vulnerabilities** - Default security issues

## Security Scope

We test security on the following components:

- ✅ EA Code (Expert Advisor)
- ✅ Data Processing
- ✅ Risk Management
- ✅ Broker Communication

Out of Scope:

- ❌ Vulnerabilities in third-party platforms (MetaTrader, Broker)
- ❌ User configuration issues
- ❌ Vulnerabilities in external dependencies

## Supported Versions

| Version | Supported | Status |
|---------|-----------|--------|
| 1.x     | ✅ Yes    | Active |

## Security Advisories

When security vulnerabilities are discovered:

1. A fix will be prepared
2. An advisory will be published in the README
3. Users will be notified appropriately
4. Changelog will be updated

## Best Practices

As a user, we recommend:

- ✅ Keep MetaTrader 5 updated
- ✅ Use strong passwords for trading accounts
- ✅ Do not share EA files with modified code
- ✅ Audit code before using on live account
- ✅ Keep backups of configurations
- ✅ Review transaction logs regularly

## Contact

For security questions, please contact us through a secure channel. Contact details should be requested through the repository.

## Transparency

We are committed to:

- Quick investigation of all reports
- Clear communication during the process
- Responsible disclosure of vulnerabilities
- Recognition of security researchers (if desired)
