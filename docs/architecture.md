# UniNet Architecture & Design Specification

UniNet is engineered as a lightweight, modular Linux utility that solves a common frustration for university students and staff: navigating captive network portals every time their laptops connect to campus Wi-Fi.

---

## 1. Design Principles

1. **Zero Runtime Bloat**: Core connectivity probing, network detection, and CLI logic rely strictly on the Python Standard Library and native Linux utilities (`nmcli`). It does not require bloated GUI runtimes or heavyweight frameworks.
2. **Distribution Agnostic**: Works on any Linux distribution running NetworkManager (Ubuntu, Fedora, Debian, Arch Linux, openSUSE, etc.).
3. **Pluggable & Extensible Providers**: The authentication layer is decoupled from network probing. Each university or hardware vendor (Fortinet, Aruba, Cisco, Mikrotik) is treated as a pluggable provider module.
4. **Security by Default**: Never stores cleartext passwords in configuration files. Integrates with the FreeDesktop Secret Service standard (GNOME Keyring, KWallet, KeePassXC).
5. **Event-Driven Automation**: Integrates with NetworkManager dispatcher scripts (`/etc/NetworkManager/dispatcher.d/`) to execute only when an interface state changes, consuming zero background RAM when idle.

---

## 2. System Architecture

```
+-------------------------------------------------------------+
|                         uninet CLI                          |
|         (status | test | login | logout | config)           |
+-------------------------------------------------------------+
                               |
       +-----------------------+-----------------------+
       |                                               |
       v                                               v
+-------------------------------+             +-------------------------------+
|     uninet.network            |             |     uninet.portal             |
|  - Queries nmcli / D-Bus      |             |  - HTTP 204 Probe Engine      |
|  - Discovers active SSID      |             |  - Detects 302/307 Redirects  |
|  - Validates campus network   |             |  - Captures Landing URL & HTML|
+-------------------------------+             +-------------------------------+
                                                       |
                                                       v
+-------------------------------+             +-------------------------------+
|     uninet.credentials        |             |     uninet.auth (Providers)   |
|  - FreeDesktop Secret Service |             |  - BaseAuthProvider           |
|  - File permission fallback   | <---------> |  - GenericFormExtractor       |
|  - Secure prompt interface    |             |  - University Providers       |
+-------------------------------+             +-------------------------------+
```

---

## 3. Component Details

### 3.1 Network Detection (`uninet.network`)
The network detector executes `nmcli -t -f ...` with machine-readable terse delimiters (`:`) to determine:
- Active Wi-Fi interface (e.g., `wlan0`, `wlp2s0`).
- Current BSSID, SSID, and signal strength.
- Device state (`connected`, `connecting`, `disconnected`).

This avoids linking against native C GObject introspection libraries, guaranteeing that UniNet runs seamlessly across Python virtual environments without compiling native extensions.

### 3.2 Captive Portal Detection (`uninet.portal`)
Captive portals work by intercepting outbound HTTP traffic (port 80) and either:
1. Returning an **HTTP 302/307 Redirect** to their portal gateway.
2. Returning an **HTTP 200 OK** with a customized captive HTML page instead of the expected payload.
3. Hijacking DNS queries.

UniNet queries standard probe endpoints:
- `http://connectivitycheck.gstatic.com/generate_204` (Expects HTTP 204 No Content, zero body).
- `http://connectivity-check.ubuntu.com/check_network_status.txt` (Expects specific plain text).

If a probe returns a non-204 status code or follows a redirect to an external hostname, UniNet flags the network as `CAPTIVE_PORTAL` and extracts:
- Redirection history.
- Portal Landing URL.
- Query parameters (often containing MAC address, client IP, or session token).
- Initial HTML payload.

### 3.3 Provider Architecture (`uninet.auth`)
Providers inherit from `BaseAuthProvider`:
```python
class BaseAuthProvider(ABC):
    @abstractmethod
    def can_handle(self, portal_url: str, html_content: str) -> bool:
        """Determines if this provider matches the portal."""
        pass

    @abstractmethod
    def login(self, session: requests.Session, credentials: dict) -> AuthResult:
        """Executes the authentication request flow."""
        pass

    @abstractmethod
    def logout(self, session: requests.Session) -> bool:
        """Terminates the portal session."""
        pass
```

A `GenericFormExtractor` parses `<form>` elements and hidden CSRF fields for standard university portals that use conventional form submission.

### 3.4 Linux Automation
1. **NetworkManager Dispatcher**:
   NetworkManager executes scripts in `/etc/NetworkManager/dispatcher.d/` whenever an interface state changes.
   When `ACTION="up"` and `CONNECTION_ID` or `SSID` matches the configured campus Wi-Fi, the dispatcher invokes `uninet login`.
2. **systemd**:
   A user unit template (`systemd/uninet.service`) is provided for users who prefer standard systemd user timers or systemd-networkd setups.
