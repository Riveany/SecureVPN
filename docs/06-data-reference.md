# Data reference

## `config.json`

Created automatically on first run by `Load-Config`
([AutoVPN.ps1:292](../AutoVPN.ps1)) if absent or unparseable. Written by
`Save-Config` as UTF-8 JSON. Gitignored.

Located beside the script or executable, at `$Script:ScriptDir\config.json`.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `vpn_client_path` | string | `C:\Program Files (x86)\VMware\SSL VPN-Plus Client\SVPClient.exe` | Absolute path to the VMware client executable. Validated with `Test-Path` before launch. |
| `connection_name` | string | `ADA-VPN` | Display label only. Shown in the GUI and in the startup log line. It is **not** used to select a network in the client — the client's own selection is used as-is. |
| `auto_connect` | bool | `false` | When true, `Main` schedules `Connect-VPN` on a 1-second timer after the form is shown. |
| `minimize_to_tray` | bool | `true` | When true, minimising the window hides it instead ([AutoVPN.ps1:1792](../AutoVPN.ps1)). |
| `credential_file` | string | `vpn_cred.dat` | Path to the credential store. Resolved relative to `$Script:ScriptDir` unless already rooted ([AutoVPN.ps1:318](../AutoVPN.ps1)). |
| `version` | string | `2.0` | Config schema version. Written but never read. |

The file is loaded exactly once, at the start of `Main`. Manual edits require a
restart; edits through the Settings dialog apply immediately.

If the JSON fails to parse, `Load-Config` silently discards it and overwrites the
file with defaults. There is no backup and no warning, so a hand-edit with a
syntax error loses the previous settings.

## `vpn_cred.dat`

Created by `Save-VpnCredential` ([AutoVPN.ps1:326](../AutoVPN.ps1)). Gitignored.

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
([AutoVPN.ps1:341](../AutoVPN.ps1)). The connect sequence then aborts and directs
the user to Settings.

### Plaintext exposure

The password exists in plaintext in process memory in two places:

1. Inside `Load-VpnCredential`, which converts the `SecureString` back to a plain
   string via `PSCredential.GetNetworkCredential().Password`
   ([AutoVPN.ps1:341](../AutoVPN.ps1)) and returns it in a hashtable.
2. In `Connect-VPN`, which holds it until `Fill-AuthForm` has sent it.

`Connect-VPN` nulls both variables and calls `[System.GC]::Collect()` immediately
after use ([AutoVPN.ps1:981](../AutoVPN.ps1)). This shortens the exposure window
but does not eliminate it — .NET string interning and the `WM_SETTEXT` payload
mean the value may still be recoverable from a memory dump.

This is a deliberate trade-off: the VMware client's authentication dialog accepts
text, so the plaintext must exist at some point.

### Deletion

`Reset-VpnCredential` ([AutoVPN.ps1:367](../AutoVPN.ps1)) removes the file with
`Remove-Item -Force`. It is a plain delete, not a secure wipe.

## Auto-start task

`Set-AutoStart` registers or removes a scheduled task named **`AutoVPN`**,
triggered at logon for the current user. Inspect it with:

```powershell
Get-ScheduledTask -TaskName AutoVPN | Select-Object -ExpandProperty Settings
(Get-ScheduledTask -TaskName AutoVPN).Actions[0]
```

Registered settings: `Hidden`, `LogonType = Interactive`, `RunLevel = Limited`,
no execution time limit, and battery-safe (`AllowStartIfOnBatteries`,
`DontStopIfGoingOnBatteries`). Interactive is not optional — the automation
drives SVPClient's windows, which do not exist in session 0. See
[04-background-service.md](04-background-service.md).

The action runs `powershell.exe -ExecutionPolicy Bypass -STA -WindowStyle Hidden
-File "<dir>\AutoVPN.ps1" -Background`, resolved by `Get-AutoStartCommand` from
whatever sits beside the running script.

`Test-AutoStart` reports whether the task exists; the Settings checkbox reads it,
and Save only touches the task when the checkbox actually changed.

### Replaced: the Startup shortcut

Earlier versions wrote `AutoVPN.lnk` into
`[Environment]::GetFolderPath("Startup")`, targeting `app.bat`. That was fragile:
`app.bat` hardcodes `D:\SecureVPN\AutoVPN.ps1`, so a copy of the project
elsewhere would have launched the wrong script.

`Set-AutoStart` deletes any leftover `AutoVPN.lnk` on **every** call, enable or
disable, so a machine upgrading from an older version cannot end up with both
launchers firing.

## Icons

| File | Use |
|---|---|
| `AutoVPN.ico` | Application icon, embedded by [`build.bat`](../build.bat) |
| `connected.ico` | Present in the working tree, untracked, and not referenced by any code |

The tray icon is not loaded from either file. It is drawn at runtime — a
DodgerBlue filled ellipse on a 16×16 bitmap, converted with `Icon.FromHandle`
([AutoVPN.ps1:1744](../AutoVPN.ps1)). Its colour does not change with connection
state; only the tooltip text does, via `Update-UIState`.

`Icon.FromHandle` is used without a matching `DestroyIcon` call, so the icon
handle is leaked. With a single tray icon created once at startup this is
inconsequential.

## Gitignored files

From [`.gitignore`](../.gitignore): `config.json` and `vpn_cred.dat` are both
excluded. Neither should ever be committed — the first contains a machine-specific
path, and the second contains credentials that, while encrypted, are still
credentials.
