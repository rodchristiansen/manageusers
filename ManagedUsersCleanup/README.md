# Managed Users Cleanup

A Prefs / Run / Logs window for manageusers, installed as
`/Applications/Utilities/Managed Users Cleanup.app`. It ships inside the one
`manageusers` package, which also puts the tool in `/usr/local/manageusers/manageusers`,
with a `/usr/local/bin/manageusers` symlink. Data and logs stay under `/Library/Managed Users`.
The window and its helper need macOS 14 or later.

- **Prefs** edits `/Library/Preferences/com.github.manageusers.plist`: the deletion
  threshold and strategy, extra exclusions, and the admin protection
  (`DeleteAdmins`, `DeletableAdmins`). A key a configuration profile manages
  shows the profile's value, locked, and is never written.
- **Run** offers two runs. *Simulate* lists the accounts the rules would delete
  and changes nothing. *Live cleanup* runs a simulation first, shows the accounts
  in a confirmation sheet, and deletes only the accounts confirmed there, each
  re-checked against the rules by the tool (`manageusers delete --live --only …`).
- **Logs** lists the day logs under `/Library/Managed Users/logs`, newest first.

## Privileged helper

The package installs `com.github.manageusers.helper` as a system LaunchDaemon, on
demand only: no RunAtLoad and no KeepAlive, so launchd starts it when the window
connects and installing the package runs nothing. It
accepts connections only from `com.github.manageusers.gui` signed by its own Team
ID, runs `/usr/local/manageusers/manageusers` (never the PATH symlink) with fixed
arguments (never a command line from the caller, and account names only from a
strict character set), writes only the five keys above, and refuses the tool when
it, `/usr/local/manageusers` or any folder above is a link or writable by anyone
but root.
An unsigned build therefore refuses every client.

## Build

```sh
make test
make app
```

`make app` builds the bundle into `build/pkg-root`; `../packaging/build-pkg.sh` calls it
and builds the one package. Set `SIGNING_IDENTITY_APP` (Developer ID Application) to
sign the helper as `com.github.manageusers.helper` and the app as
`com.github.manageusers.gui`. `packaging/make-icon.swift` regenerates `packaging/AppIcon.iconset`.
