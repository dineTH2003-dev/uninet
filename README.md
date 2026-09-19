# UniNet 🌐

> A zero-dependency multi-platform utility that automatically logs into university Wi-Fi captive portals.
> **Works on Linux, macOS, and Windows. No Python required. No dependencies.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platforms: Linux | macOS | Windows](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-orange.svg)]()
[![Dependencies: 0](https://img.shields.io/badge/Dependencies-Zero-brightgreen.svg)]()

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

## 🚀 Quick Install

Clone the repository to get started:
```bash
git clone https://github.com/dineTH2003-dev/uninet.git
cd uninet
```

### 🐧 Linux & 🍎 macOS (Auto-Detect)
Run in your terminal:
```bash
./install.sh
```
- On **Linux**: Automatically installs the NetworkManager dispatcher hook (`/etc/NetworkManager/dispatcher.d`).
- On **macOS**: Automatically installs the native `launchd` LaunchAgent (`~/Library/LaunchAgents`).

---

### 🪟 Windows (Windows 10 & 11)
Open **PowerShell as Administrator** and run:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\windows\install.ps1
```
*Uses native Windows Task Scheduler hooked to `WLAN-AutoConfig` Event 8001.*

---

## ⚡ How It Works (Zero Resources)

Unlike tools that run heavy background loops, UniNet uses an **event-driven architecture**:

- **At Home / Mobile Hotspot**: The script exits in **0.002 seconds**. 0% CPU, 0 MB RAM.
- **On Campus Wi-Fi**: The OS notifies UniNet on connection. It sends a tiny HTTP probe, submits your saved login, and exits immediately.
- **RAM Usage**: **0.0 MB** while idle.

---

## 🛠 Commands

### Linux & macOS:
```bash
# Check current connection status
uninet status

# Reconfigure username or password
uninet setup

# Force manual login
uninet login

# Uninstall UniNet
uninet uninstall
```

### Windows (PowerShell):
```powershell
# Check current status
uninet.ps1 status

# Reconfigure username or password
uninet.ps1 setup

# Force manual login
uninet.ps1 login
```

---

## 🗑 Uninstallation

If you ever want to completely remove UniNet and all hooks:

- **Linux & macOS**: `./uninstall.sh` (or `uninet uninstall`)
- **Windows**: `powershell -ExecutionPolicy Bypass -File .\scripts\windows\uninstall.ps1`

---

## License

MIT License. Free and open source for all students and staff.
