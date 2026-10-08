# Automatic Intel Updates

WaifuX's built-in updater uses Sparkle. Once the installed app is modified with Intel helper binaries and ad-hoc re-signed, its signing identity no longer matches the upstream Developer ID signed app. Sparkle can therefore reject the next official update with a signature validation error.

This repository provides an external update path for Intel Macs.

## How it works

### GitHub side

Automatic checks, builds, and release publishing on GitHub are disabled.

`.github/workflows/auto-build-latest.yml` is now manual-only: it has no scheduled or push trigger. To check for a new version and build its Intel patch, open **Actions → Build Latest WaifuX Intel Patch (Manual) → Run workflow**.

When started manually, the workflow:

1. reads the latest official version from the same appcast used by WaifuX;
2. clones the matching upstream `v<version>` tag;
3. rebuilds `wallpaper-video-renderer` for `x86_64`;
4. rebuilds `wallpaperengine-cli` for `x86_64`;
5. verifies both Mach-O binaries contain `x86_64`;
6. publishes a release named `intel-v<version>` containing the matching patch ZIP.

If the release already exists, the workflow exits without rebuilding it.

### Intel Mac side

A checker previously installed on an Intel Mac runs separately from GitHub. To stop that local checker too, use the uninstall command under **Disable automatic checking** below. With GitHub automatic builds disabled, a new matching patch must be built manually before the Mac updater can install it.

`mac/WaifuX-Intel-AutoUpdater.command`:

1. reads the official WaifuX appcast;
2. waits until the matching Intel patch release exists;
3. downloads the official upstream `WaifuX.dmg`;
4. verifies the pristine official app with `codesign` and Gatekeeper before modification;
5. backs up the currently installed WaifuX;
6. installs the fresh official version;
7. replaces the Video/Web helper binaries with the matching `x86_64` builds;
8. ad-hoc re-signs the locally modified app;
9. verifies the resulting local signature;
10. launches WaifuX.

The updater automatically restores the previous backup if an error occurs after replacing the application.

## Install the automatic checker

On the Intel Mac, download `mac/INSTALL_AUTO_CHECK.command`, then run:

```bash
bash INSTALL_AUTO_CHECK.command
```

The installer creates a LaunchAgent that checks every 30 minutes and at login.

It does **not** install updates silently as root. When both the official WaifuX update and the matching Intel patch are available, it displays a prompt. Choosing **Update now** opens the external updater in Terminal; macOS then asks for the administrator password when `/Applications/WaifuX.app` needs to be replaced.

This design avoids installing a permanent privileged/root daemon.

## Important

After an Intel patch is installed, do not use WaifuX's built-in Sparkle updater. Use the external Intel updater instead. The patched app is intentionally locally re-signed, so it does not possess the upstream author's Developer ID signing identity.

The external checker watches the same official appcast that WaifuX uses, so new releases are still detected automatically.

## Manual update

You can run the external updater at any time:

```bash
bash "$HOME/Library/Application Support/WaifuX Intel Updater/WaifuX-Intel-AutoUpdater.command"
```

If the upstream version is newer but the corresponding Intel patch has not finished building yet, the updater exits without changing the application. Run it again after the GitHub Actions build completes.

## Disable automatic checking

Run:

```bash
bash "$HOME/Library/Application Support/WaifuX Intel Updater/UNINSTALL_AUTO_CHECK.command"
```

This removes the LaunchAgent but leaves updater files and backups in place.

## Scope

Automatically patched:

- Media video wallpaper helper
- Wallpaper Engine Video
- Wallpaper Engine Web

Not patched:

- Wallpaper Engine Scene (`wallpaper-wgpu`, DXC components)
