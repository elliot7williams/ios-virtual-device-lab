# VM security and isolation model

Default lab policy is deny-by-default for host integration:

```text
Virtual machine
├── Dedicated virtual disk
├── Explicit virtual network mode
├── No shared folder
├── Clipboard disabled
└── Host integration disabled
```

Network, clipboard, shared-folder, and host-integration access must be represented in VM metadata and shown to the user. An adapter must report when it cannot enforce a requested control.

Guest diagnostics use bounded file list/download operations over the existing vphoned connection. The manager restricts automatic collection to known log/crash roots, four directory levels, 200 files, approved diagnostic extensions, and 50 MB per file. It does not expose a guest command shell.

Plugins run out of process, never at startup, and require a supported API version, declared capability/permission, explicit trust, and a pinned SHA-256 executable digest. Any executable change revokes effective trust until reviewed again.
