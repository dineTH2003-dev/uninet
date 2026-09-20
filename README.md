# UniNet 🌐

> A zero-dependency multi-platform utility that automatically logs into university Wi-Fi captive portals.
> **Works on Linux, macOS, and Windows. No Python required. No dependencies.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platforms: Linux | macOS | Windows](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-orange.svg)]()
[![Dependencies: 0](https://img.shields.io/badge/Dependencies-Zero-brightgreen.svg)]()
[![Downloads](https://img.shields.io/github/downloads/dineTH2003-dev/uninet/total.svg?color=007ec6&label=downloads)](https://github.com/dineTH2003-dev/uninet/releases)

---

## What It Does

Connecting to campus Wi-Fi normally requires:
1. Connecting to Wi-Fi.
2. Opening a browser.
3. Getting redirected to a captive portal.
4. Typing your student username and password every single day.

**UniNet automates this entire process across all major operating systems.** 
Whenever your laptop connects to university Wi-Fi, UniNet silently logs you in. **You never have to open the login page again.**

### Supported Networks:
- **`UoM_Wireless`**
- **`UoM.Wireless`**
- **`UoM-Wireless`**

*(Save your credentials once, and it automatically connects across all three networks!)*

---

## 🚀 1-Line Web Installation (Recommended)

No manual downloads or `git clone` needed. Simply copy and paste the command for your operating system into your terminal:

### 🐧 Linux & 🍎 macOS
Open your terminal and run:
```bash
curl -fsSL https://raw.githubusercontent.com/dineTH2003-dev/uninet/main/install.sh | bash
```
- **Zero Configuration**: Automatically detects your OS (Linux vs macOS).
- **Auto-Dependency Healing**: Automatically detects and installs required system packages (`curl`, `NetworkManager`) via `apt`, `dnf`, `pacman`, or `zypper`.
- **Zero-Touch Background Hook**: Automatically configures NetworkManager dispatcher on Linux or `launchd` on macOS.

---

### 🪟 Windows (Windows 10 & 11)
Open **PowerShell as Administrator** and run:
```powershell
irm https://raw.githubusercontent.com/dineTH2003-dev/uninet/main/scripts/windows/install.ps1 | iex
```
- **Native & Dependency-Free**: 100% pure PowerShell. No Python or extra software required.
- **Event-Driven**: Registers Windows Task Scheduler hook for `WLAN-AutoConfig` Event 8001.
- **Global Command**: Adds `uninet` directly to your system PATH for CMD and PowerShell.

---

## 📦 Alternative: Local Installation

If you prefer cloning the repository manually:
```bash
git clone https://github.com/dineTH2003-dev/uninet.git
cd uninet

# Linux & macOS:
./install.sh

# Windows (Run PowerShell as Administrator):
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\windows\install.ps1
```

---

## ⚡ How It Works (Zero Resources)

Unlike tools that run heavy background loops, UniNet uses an **event-driven architecture**:

- **At Home / Mobile Hotspot**: The script exits in **0.002 seconds**. 0% CPU, 0 MB RAM.
- **On Campus Wi-Fi**: The OS notifies UniNet on connection. It sends a tiny HTTP probe, submits your saved login, and exits immediately.
- **RAM Usage**: **0.0 MB** while idle.

---

## 🛠 Commands

### 🐧 Linux & 🍎 macOS:
```bash
# Automatically find and switch to highest-speed / 5 GHz campus AP
uninet optimize

# Scan and display all visible campus networks with quality scores
uninet scan

# Check current connection status
uninet status

# Reconfigure username or password
uninet setup

# Register UoM SSIDs for automatic Wi-Fi join (runs automatically during setup)
uninet trust

# Force manual login
uninet login

# Check for and install the latest update
uninet update

# Uninstall UniNet
uninet uninstall
```

### 🪟 Windows (PowerShell / Command Prompt):
```powershell
# Automatically find and switch to highest-speed / 5 GHz campus AP
uninet optimize

# Scan and display all visible campus networks with quality scores
uninet scan

# Check current status
uninet status

# Reconfigure username or password
uninet setup

# Register UoM SSIDs for automatic Wi-Fi join (runs automatically during setup)
uninet trust

# Force manual login
uninet login

# Check for and install the latest update
uninet update

# Completely remove UniNet
uninet uninstall
```

---

## 🔄 Updating UniNet

UniNet includes a built-in zero-dependency self-updater that upgrades to the latest release while keeping your saved student credentials completely intact:
```bash
uninet update
```
Whenever an update is available on GitHub, running `uninet status` or `uninet scan` will also display a subtle notification banner reminding you to upgrade.

---

## 🔑 Changing Credentials / Fixing a Typo

If you entered your Student Username or Password incorrectly, or changed your campus password:
```bash
uninet setup
```
Run this on **Linux, macOS, or Windows** at any time. It will prompt for your updated credentials and securely overwrite the local configuration.

---

## 🗑 Uninstallation

You can completely remove UniNet and all background hooks using either method:

### Method 1: Global CLI Command (Recommended)
Open your terminal (or PowerShell as Administrator on Windows) and run:
```bash
uninet uninstall
```

### Method 2: 1-Line Web Uninstaller
If you already deleted files or prefer a clean web command:

**🐧 Linux & 🍎 macOS**:
```bash
curl -fsSL https://raw.githubusercontent.com/dineTH2003-dev/uninet/main/uninstall.sh | bash
```

**🪟 Windows (PowerShell as Administrator)**:
```powershell
irm https://raw.githubusercontent.com/dineTH2003-dev/uninet/main/scripts/windows/uninstall.ps1 | iex
```

---

## License

MIT License. Free and open source for all students and staff.
