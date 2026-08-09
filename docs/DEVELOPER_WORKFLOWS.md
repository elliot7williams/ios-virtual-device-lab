# Developer workflows

## App artifacts and test matrices

IPA/TIPA builds can be copied into the lab artifact library once and reused across devices. A deployment matrix boots each selected stopped VM, deploys the build, evaluates configured assertions, captures requested screenshots/diagnostics, stops the VM, and writes JSON and Markdown reports.

Current assertions cover guest readiness, deployment completion, screenshot creation, clean backend exit, diagnostic collection, and maximum duration. Additional UI-tree, text, image-diff, audio, and app-specific assertions can be added without changing the engine interface.

## Xcode

The Developer Tools screen detects `xcode-select` and `xcodebuild` and generates `vdl-deploy.sh`. Add the helper as an Xcode Run Script or invoke it after export:

```sh
vdl-deploy.sh <virtual-device-name> <path-to-app.ipa>
```

This is an explicit deployment bridge. Virtual devices are not advertised as Apple CoreSimulator destinations because they are not CoreSimulator runtimes.

## Automation

Custom workflows support ordered actions, per-step values, delay, retries, running/stopped conditions, continue-on-failure, scheduling metadata, and headless metadata. Scheduling metadata is persisted for an external CI/scheduler; the desktop app does not silently install a background launch agent.
