# Development Guide

This guide explains how to test, debug, and contribute to UniNet.

---

## 1. Prerequisites

- Any Linux distribution (Ubuntu, Debian, Fedora, Arch Linux, Linux Mint, etc.)
- `bash`
- `curl`
- `nmcli` (NetworkManager)

**No Python, compilers, or build tools are required.**

---

## 2. Local Testing

Clone the repository and test directly:

```bash
git clone https://github.com/dineTH2003-dev/uninet.git
cd uninet

# Test the binary directly
./bin/uninet status
./bin/uninet --help
```

---

## 3. Testing Login Simulation

To simulate a login without submitting real credentials:
```bash
./bin/uninet login
```

If connected to a non-university Wi-Fi (Home / Hotspot), notice how UniNet exits cleanly in 0.002 seconds:
```bash
./bin/uninet login
# Output: [UniNet] Connected to non-university Wi-Fi (...). Exiting.
```

---

## 4. Linting and Shell Check

If you want to verify shell script syntax:
```bash
bash -n bin/uninet
bash -n install.sh
bash -n scripts/99-uninet.sh
```

Or using `shellcheck` (optional):
```bash
shellcheck bin/uninet
```
