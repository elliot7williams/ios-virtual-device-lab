# Security policy

Please do not publish host security details, Apple credentials, firmware decryption material, production app secrets, or personal VM archives in an issue.

For a vulnerability in this manager, open a private GitHub security advisory in the repository. For a vulnerability in `vphone-cli`, report it to that upstream project.

This project executes a separately installed backend and user-installed plugins. Review every plugin descriptor and executable before granting trust. Plugins never run automatically; the app checks API version, capability permission, explicit trust, and a pinned executable SHA-256 before execution.

Guest diagnostic export is intentionally bounded and does not expose a general guest shell. See `docs/SECURITY_MODEL.md` for roots, depth, count, extension, and file-size limits.

Supported security fixes are delivered on the latest release line. Private reports should include impact, affected version, reproduction steps, and a minimal sanitized proof. Maintainers should acknowledge a report within seven days and coordinate disclosure after a fix is available; do not include exploit material or private data in a public issue.
