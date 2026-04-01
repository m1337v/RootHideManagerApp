# RHInject

`RHInject` is a standalone RootHide utility app for managing:

- classic RootHide hidden-app rules from `RootHideConfig.plist`
- unified injection modes for RootHide-based forks
- whitelist and blacklist injection lists
- whitelist helper plists such as `inject.system`, `inject.wantsblacklist`, and `jetsam.addend`
- `varClean` cleanup and custom `varCleanRules-custom.plist` overrides

It is intended to work as an extended manager on stock RootHide as well as on Opamine's unified-mode branch.

## What It Adds

- `RootHide` tab for the stock hidden-app list
- `Whitelist` tab for `default-off + allowlist` injection setups
- `Blacklist` tab for `default-on + denylist` injection setups
- `Settings` tab with:
  - runtime mode switching
  - userspace reboot and standard respring actions
  - HideApps maintenance helpers
  - in-app editors for `inject.system`, `inject.wantsblacklist`, and `jetsam.addend`
  - in-app `varClean` rule editing
- `varClean` tab with destructive cleanup confirmation before deleting selected paths

## HideApps Flow

`RHInject` treats HideApps as a reversible maintenance tool:

- `HideApps` unregisters TrollStore and jailbreak apps from LaunchServices
- `Refresh App Registrations` is the explicit undo path that rebuilds app registrations from disk
- `Rebuild Icon Cache` refreshes icon cache state after registration changes
- `Standard Respring` is available separately when you want SpringBoard restarted without a full userspace reboot

## Compatibility

`RHInject` reads and writes the same RootHide plist layout used by the existing manager-style apps:

- `/var/mobile/Library/RootHide/RootHideConfig.plist`
- `/var/mobile/Library/RootHide/cn.zqbb.inject.plist`
- `/var/mobile/Library/RootHide/cn.zqbb.inject.system.plist`
- `/var/mobile/Library/RootHide/cn.zqbb.inject.wantsblacklist.plist`
- `/var/mobile/Library/RootHide/cn.zqbb.jetsam.addend.plist`
- `/var/mobile/Library/RootHide/varCleanRules-custom.plist`
- legacy `/var/mobile/zp.unject.plist`

That makes it useful on stock RootHide too, even without Opamine-specific changes.

## Build

```sh
make package FINALPACKAGE=1
```

The built package is written to `packages/`.

## Releases

Pushes to the `rhinject` branch build a `.deb` in GitHub Actions and publish/update the `RHInject` release.
