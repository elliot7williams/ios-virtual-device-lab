# Developer workflows

## App artifacts and test matrices

IPA/TIPA builds can be copied into the lab artifact library once and reused across devices. A deployment matrix boots each selected stopped VM, deploys the build, evaluates configured assertions, captures requested screenshots/diagnostics, stops the VM, and writes JSON and Markdown reports.

Assertions cover guest readiness, deployment completion, screenshot creation/content, screenshot-to-baseline similarity, expected log text, network mode, runtime audio configuration, CPU/memory ceilings, clean backend exit, diagnostic collection, and maximum duration. UI-tree assertions remain gated on a guest accessibility API.

## Xcode

The Developer Tools screen detects `xcode-select` and `xcodebuild` and generates `vdl-deploy.sh`. Add the helper as an Xcode Run Script or invoke it after export:

```sh
vdl-deploy.sh <virtual-device-name> <path-to-app.ipa>
```

The helper delegates to `vdlctl deploy`, writes machine-readable evidence under Xcode's derived files, and returns a stable nonzero status when an assertion fails. This is an explicit deployment bridge. Virtual devices are not advertised as Apple CoreSimulator destinations because they are not CoreSimulator runtimes.

## Automation

Custom workflows support ordered actions, per-step values, delay, retries, running/stopped conditions, continue-on-failure, scheduling metadata, and headless metadata. `vdlctl run` executes them unattended; `vdlctl schedule-install` installs an explicit per-user launchd agent only when invoked by the user.

See [Headless automation](HEADLESS_AUTOMATION.md) for CLI and CI examples.
