# Diagnostic privacy and assisted analysis

The standard diagnostic path is:

```text
Collect raw local evidence
        ↓
Apply size/category policy
        ↓
Redact secret and personal-data patterns
        ↓
Write PRIVACY-PREVIEW.json
        ↓
Remove the generated raw bundle
        ↓
Local deterministic classification
        ↓
Optional trusted analyzer plugin (explicit opt-in)
```

The local classifier recognizes common app-crash, VM-crash, boot-failure, kernel-panic, memory-pressure, network, and audio signatures. It produces evidence and next-action suggestions but never modifies a VM or compatibility claim.

Analyzer plugins must declare the `diagnostic-analysis` capability, be explicitly trusted, retain their pinned executable checksum, and receive only `LAB_DIAGNOSTIC_BUNDLE` pointing to the sanitized directory. No diagnostic data is uploaded by the built-in analyzer.

Encrypted `.vdlenc` exports use AES-GCM with a random 128-bit salt and a 200,000-round PBKDF2-HMAC-SHA256 key derivation. The passphrase is not saved. Because pattern redaction is necessarily best-effort, inspect `PRIVACY-PREVIEW.json` and the sanitized contents before sharing them.
