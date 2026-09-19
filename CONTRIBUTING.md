# Contributing to UniNet

Thank you for your interest in contributing to **UniNet**! We welcome contributions from students, developers, and Linux enthusiasts to make university Wi-Fi authentication effortless.

---

## Code of Conduct

Please be respectful, collaborative, and considerate in all interactions within this project.

---

## How to Contribute

### 1. Adding a New University Provider
If you want to add automated login support for your university:
1. Inspect your university captive portal using our [Portal Analysis Guide](docs/portal-analysis.md).
2. Create an issue with the form fields and redirection flow (without credentials!).
3. Implement a provider module in `src/uninet/providers/<your_university>.py` inheriting from `BaseAuthProvider`.
4. Add unit tests for your provider in `tests/test_providers/`.
5. Submit a pull request.

### 2. Reporting Bugs
- Open an issue on GitHub.
- Include your Linux distribution (Ubuntu, Fedora, Arch, Debian, etc.).
- Run `uninet test --json` (redacting any private details) and attach the diagnostic output.

### 3. Development Workflow
1. Fork and clone the repository:
   ```bash
   git clone https://github.com/dineTH2003-dev/uninet.git
   cd uninet
   ```
2. Set up a virtual environment and install in editable mode with dev dependencies:
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -e ".[dev]"
   ```
3. Run the test suite:
   ```bash
   pytest
   ```
4. Follow PEP 8 style standards and write unit tests for any new features.

---

## Commit Guidelines
We use conventional commit messages:
- `feat: add fortinet captive portal provider`
- `fix: handle empty SSID when Wi-Fi is disconnected`
- `docs: update portal analysis guide`
- `test: add mock tests for HTTP 307 captive portal redirects`
