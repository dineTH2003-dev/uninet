# Security Policy

## Security Architecture

UniNet is designed with a strict security-first model:
1. **Local Storage Only**: Student credentials are saved strictly on the local machine (`~/.config/uninet/credentials.json`).
2. **Permission Locking**: All credential files are created with mode `0600` (`-rw-------`), meaning no other local users or unprivileged processes can read them.
3. **No External Telemetry**: UniNet never transmits credentials, telemetry, or analytics to any third-party server. Requests are directed exclusively to Google's standard connectivity probe (`generate_204`) and your local university gateway.
4. **Whitelisted Execution**: The auto-connect engine strictly exits when connected to non-university networks (e.g. Home Wi-Fi, Mobile Hotspots), ensuring your university credentials are never sent to external servers.

## Reporting a Vulnerability

If you discover a security vulnerability or credential leak issue in UniNet:
1. Please **do NOT** open a public issue on GitHub.
2. Email the maintainers directly or submit a private security advisory through GitHub's Security Advisories tab.
3. We will respond within 48 hours to investigate and release a patch.
