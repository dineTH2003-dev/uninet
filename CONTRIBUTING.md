# Contributing to UniNet

Thank you for your interest in contributing to **UniNet**! We welcome contributions from students, developers, and sysadmins to make university Wi-Fi authentication effortless.

---

## Code of Conduct

Please be respectful, collaborative, and considerate in all interactions within this project.

---

## How to Contribute

### 1. Adding Support for Another University
If your university also uses a captive portal and you want to adapt UniNet:
1. Inspect your captive portal's login form using your browser DevTools (Network tab).
2. Note the form `action` URL, and field names (e.g. `username`, `password`, `user`, `pass`).
3. Open an issue with the portal flow details — **never include real credentials**.
4. Submit a pull request adapting the login logic in `bin/uninet` (Linux/macOS) or `bin/uninet.ps1` (Windows).

### 2. Reporting Bugs
- Open an issue on GitHub.
- Include your OS and version (e.g. Ubuntu 24.04, macOS 14, Windows 11).
- Run `uninet status` and attach the output (redact any private details).

### 3. Development Workflow

UniNet is **zero-dependency** — no Python, no pip, no virtual environments.
The engines are pure shell scripts:

| File | Platform | Language |
|------|----------|----------|
| `bin/uninet` | Linux | Bash |
| `bin/uninet-macos` | macOS | Bash |
| `bin/uninet.ps1` | Windows | PowerShell 5.1+ |
| `install.sh` | Linux + macOS | Bash |
| `scripts/windows/install.ps1` | Windows | PowerShell |

**Clone and run locally:**
```bash
git clone https://github.com/dineTH2003-dev/uninet.git
cd uninet

# Lint all shell scripts
make lint

# Run the full captive portal simulation test suite
make test
```

**Requirements for development:**
- `bash` 4+
- `shellcheck` (install with `apt install shellcheck` or `brew install shellcheck`)
- `curl`, `nmcli` (Linux) / `networksetup` (macOS)

### 4. PowerShell Constraint (Important)
`bin/uninet.ps1` and all `.ps1` files **must remain 100% ASCII** — no Unicode characters (no `✔`, `✨`, `•`, em-dashes, etc.).

This is because Windows PowerShell 5.1 on GitHub Actions reads `.ps1` files without BOM in Windows-1252 mode, which corrupts multi-byte UTF-8 characters and breaks AST parsing.

Use `[+]` instead of `✔`, `-` instead of `•`, etc.

---

## Commit Guidelines

We use conventional commit messages:
- `feat: register UoM SSIDs as preferred open networks on setup`
- `fix: handle empty SSID when Wi-Fi is disconnected`
- `docs: update portal analysis guide`
- `test: add mock test for HTTP 307 captive portal redirect`

---

## Testing

The test suite runs a local mock captive portal server and validates:
1. HTTP 302 probe detection
2. Form action URL extraction
3. POST credential submission
4. HTTP 204 post-login verification
5. Multi-factor AP quality scoring
6. Hysteresis margin (anti-flap) logic

Run with: `make test`

CI runs automatically on every push and pull request via GitHub Actions across Linux, macOS, and Windows runners.
