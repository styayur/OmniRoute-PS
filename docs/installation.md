# Install, recover and remove

[Back to README](../README.md).

## Recommended: reviewed checkout or release archive

PowerShell 7.4+ is required. Clone the repository or download `OmniRoute-PS-v0.2.0.zip` and `SHA256SUMS.txt` from [v0.2.0](https://github.com/styayur/OmniRoute-PS/releases/tag/v0.2.0). Before extracting the downloaded ZIP:

```powershell
Get-FileHash ./OmniRoute-PS-v0.2.0.zip -Algorithm SHA256
Get-Content ./SHA256SUMS.txt
```

Compare the complete hash for that exact filename. Stop if it differs. A checksum detects corruption; it is not an independent signature. Review local scripts before executing them. No remote-script execution, global installation or execution-policy change is needed.

Run from the extracted/clone directory and pass `-ConfigPath` explicitly. The CLI resolves default configuration against the script root, with `OMNIROUTE_CONFIG` taking precedence over the default files. `check` and `test` without `-Live` do not contact upstreams. `status` and `providers` can query the local listener; `test -Live` makes upstream network probes.

Stop `serve` with Ctrl+C. Back up your JSON outside the checkout before editing or replacing it. Restore that file and run `check` before restarting. Invalid hot reload keeps the last valid in-memory configuration; this is not an on-disk backup. Listening address/port changes require restart. Runtime health and circuit state reset on restart.

To remove a checkout, stop the router, preserve your configuration, then remove that specific directory. Clear provider environment variables wherever you set them; deleting the checkout does not remove those variables or revoke keys.

## Optional installer: current limitations

`scripts/install.ps1` copies into `$HOME/.omniroute`; `-AddToPath` changes the user PATH only when requested. It does not install a service. The script has no Dry Run/WhatIf mode.

Source audit on 2026-10-16 found two defects: the non-Windows launcher resolves the entry script one directory too high, and the failure-recovery condition passes `-and` to `Test-Path` instead of evaluating a Boolean expression. The existing suite does not cover these installer paths. Use the reviewed checkout workflow pending a tested repair; do not rely on automatic rollback.

Existing default installations can be removed with the command below **after backing up configuration**. Uninstall recursively deletes the entire installation directory and removes its user PATH entry, including a pre-existing matching entry. Custom roots must be dedicated directories under your home; never point the installer at a directory containing unrelated files. For a custom installation, pass its exact `-InstallRoot` during uninstall; it is not inferred from the script location.

```powershell
pwsh "$HOME/.omniroute/scripts/install.ps1" -Uninstall
```

`-Force` replacement deletes the old installation backup after a successful copy, so it is not a configuration-preserving upgrade. Back up separately before any replacement. The release archive contains the release's scripts, not later documentation changes on `main`.
