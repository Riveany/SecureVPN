# Data reference

## `config.json`

Created automatically on first run by `Load-Config`
([AutoVPN.ps1:241](../AutoVPN.ps1)) if absent or unparseable. Written by
`Save-Config` as UTF-8 JSON. Gitignored.

Located beside the script or executable, at `$Script:ScriptDir\config.json`.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `vpn_client_path` | string | `C:\Program Files (x86)\VMware\SSL VPN-Plus Client\SVPClient.exe` | Absolute path to the VMware client executable. Validated with `Test-Path` before launch. |
| `connection_name` | string | `ADA-VPN` | Display label only. Shown in the GUI and in the startup log line. It is **not** used to select a network in the client — the client's own selection is used as-is. |
| `auto_connect` | bool | `false` | When true, `Main` schedules `Connect-VPN` on a 1-second timer after the form is shown. |
| `minimize_to_tray` | bool | `true` | When true, minimising the window hides it instead ([AutoVPN.ps1:1355](../AutoVPN.ps1)). |
| `credential_file` | string | `vpn_cred.dat` | Path to the credential store. Resolved relative to `$Script:ScriptDir` unless already rooted ([AutoVPN.ps1:267](../AutoVPN.ps1)). |
| `version` | string | `2.0` | Config schema version. Written but never read. |

The file is loaded exactly once, at the start of `Main`. Manual edits require a
restart; edits through the Settings dialog apply immediately.

If the JSON fails to parse, `Load-Config` silently discards it and overwrites the
file with defaults. There is no backup and no warning, so a hand-edit with a
syntax error loses the previous settings.

## `vpn_cred.dat`

Created by `Save-VpnCredential` ([AutoVPN.ps1:275](../AutoVPN.ps1)). Gitignored.

### Format

UTF-8 JSON with two fields, each a DPAPI-encrypted string produced by
`ConvertFrom-SecureString`:

```json
{
  "u": "01000000d08c9ddf0115d1118c7a00c04fc297eb...",
  "p": "01000000d08c9ddf0115d1118c7a00c04fc297eb..."
}
```

`u` is the username and `p` is the password. Both are encrypted, not just the
password.

### Encryption

`ConvertFrom-SecureString` without a `-Key` argument uses the Windows Data
Protection API with the current user's key. The consequences:

- The file can only be decrypted by **the same Windows user account on the same
  machine**. Copying it to another machine, or to another user profile, makes it
  unreadable.
- No master password is involved. Any process running as that user can decrypt
  it, including any script the user runs.
- A Windows profile reset or a user-account recreation destroys the key, and the
  stored credentials become permanently undecryptable.

If decryption fails, `Load-VpnCredential` catches the exception, logs
`Failed to load credentials`, and returns `$null`
([AutoVPN.ps1:307](../AutoVPN.ps1)). The connect sequence then aborts and directs
the user to Settings.

### Plaintext exposure

The password exists in plaintext in process memory in two places:

1. Inside `Load-VpnCredential`, which converts the `SecureString` back to a plain
   string via `PSCredential.GetNetworkCredential().Password`
   ([AutoVPN.ps1:302](../AutoVPN.ps1)) and returns it in a hashtable.
2. In `Connect-VPN`, which holds it until `Fill-AuthForm` has sent it.

`Connect-VPN` nulls both variables and calls `[System.GC]::Collect()` immediately
after use ([AutoVPN.ps1:790](../AutoVPN.ps1)). This shortens the exposure window
but does not eliminate it — .NET string interning and the `WM_SETTEXT` payload
mean the value may still be recoverable from a memory dump.

This is a deliberate trade-off: the VMware client's authentication dialog accepts
text, so the plaintext must exist at some point.

### Deletion

`Reset-VpnCredential` ([AutoVPN.ps1:316](../AutoVPN.ps1)) removes the file with
`Remove-Item -Force`. It is a plain delete, not a secure wipe.

## Auto-start shortcut

`Set-AutoStart` ([AutoVPN.ps1:1151](../AutoVPN.ps1)) creates or removes
`AutoVPN.lnk` in the current user's Startup folder
(`[Environment]::GetFolderPath("Startup")`).

The shortcut targets [`app.bat`](../app.bat), sets the working directory to
`$Script:ScriptDir`, and uses `WindowStyle = 7` (minimised).

Note that it targets `app.bat` specifically, not `AutoVPN.exe`. Enabling
auto-start from a compiled build still creates a shortcut to the batch launcher,
which in turn runs the `.ps1` from its own hardcoded absolute path. If
`app.bat` is absent the function silently does nothing.

An alternative that avoids both the Startup folder and the visible window is
described as Option C in [04-background-service.md](04-background-service.md).

## Icons

| File | Use |
|---|---|
| `AutoVPN.ico` | Application icon, embedded by [`build.bat`](../build.bat) |
| `connected.ico` | Present in the working tree, untracked, and not referenced by any code |

The tray icon is not loaded from either file. It is drawn at runtime — a
DodgerBlue filled ellipse on a 16×16 bitmap, converted with `Icon.FromHandle`
([AutoVPN.ps1:1310](../AutoVPN.ps1)). Its colour does not change with connection
state; only the tooltip text does, via `Update-UIState`.

`Icon.FromHandle` is used without a matching `DestroyIcon` call, so the icon
handle is leaked. With a single tray icon created once at startup this is
inconsequential.

## Gitignored files

From [`.gitignore`](../.gitignore): `config.json` and `vpn_cred.dat` are both
excluded. Neither should ever be committed — the first contains a machine-specific
path, and the second contains credentials that, while encrypted, are still
credentials.
