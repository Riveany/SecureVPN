# Troubleshooting

Failure modes are listed with the log line that identifies them. All log output
goes both to the GUI log box and to the console via `Write-Host`
([AutoVPN.ps1:397](../AutoVPN.ps1)); when launched through
[`app.bat`](../app.bat) the console is hidden, so the GUI log box is normally the
only place to read it.

## `ERROR: SVPClient not found at: <path>`

`vpn_client_path` in [`config.json`](../config.json) does not point at an
existing file. The default is
`C:\Program Files (x86)\VMware\SSL VPN-Plus Client\SVPClient.exe`.

Verify the real path and correct the config. Note that the value is read once at
startup by `Load-Config`, so the application must be restarted after editing.

## `ERROR: Failed to start SVPClient`

The executable was launched but no process named `SVPClient` existed 3 seconds
later ([AutoVPN.ps1:449](../AutoVPN.ps1)).

Usual causes: the client requires elevation it did not receive, or it crashed on
startup. Launch `SVPClient.exe` by hand and observe what happens.

## `ERROR: Login window not found within 15s`

`Find-SVPLoginWindow` timed out. The process is running but no visible window
whose title contains `SSL VPN-Plus Client - Login` was found.

Check in order:

1. Is the client's window actually on screen, or minimised to its own tray icon?
   `IsWindowVisible` is required to return true, so a fully hidden window will not
   be found.
2. Has the client version changed the window title? Compare the actual title
   against the substring in [03-win32-reference.md](03-win32-reference.md).
3. Was the client slower than 15 seconds to show its window? The timeout is a
   parameter default at [AutoVPN.ps1:453](../AutoVPN.ps1).

## `ERROR: Could not find Login button (ID: 1018)`

The login window was found but `GetDlgItem(hwnd, 1018)` returned nothing. This
almost always means the client version changed its control IDs.

To recover the correct ID:

```powershell
$hwnd = [Win32]::FindWindowByTitle("SSL VPN-Plus Client - Login")
[Win32]::GetChildren($hwnd) | Format-Table ClassName, ControlId, Text, IsEnabled
```

Then update `ID_LOGIN_BTN` at [AutoVPN.ps1:76](../AutoVPN.ps1).

## `WARNING: Yes button not found in Security Alert`

The certificate dialog appeared but none of the three lookups matched: control
**1278** (the verified Yes button), a button labelled `Yes`/`&Yes`, or control
ID 6.

`Handle-SecurityAlert` logs every button it found, with ID and text, immediately
after this warning ([AutoVPN.ps1:563](../AutoVPN.ps1)). Read those lines — they
contain what is needed to fix the matcher, and the new ID belongs in
`ID_SECALERT_YES`.

## `ERROR: Expected 2 Edit controls (user/pass), found N`

Reached only when the verified control IDs 1012 and 1219 are both absent, so
`Fill-AuthForm` fell back to positional mapping and then found fewer than two
`Edit` controls ([AutoVPN.ps1:614](../AutoVPN.ps1)).

The dialog layout has changed. The function logs every `Edit` and `Button` with
its ID and text before this error, so the log shows the new structure — update
`ID_AUTH_USER` and `ID_AUTH_PASS` from it.

## `ERROR: Second Edit control is not a password field - aborting to avoid exposing the password`

The positional fallback found two `Edit` controls, but the second one does not
carry the `ES_PASSWORD` style, meaning it displays its contents in clear text.

`Fill-AuthForm` refuses to continue rather than typing the password into a
visible box. This is a deliberate stop, not a crash: it fires when the auth
dialog's field order has changed, which previously would have silently leaked the
password into the username field.

Recover the real IDs from the logged control list and update `ID_AUTH_USER` and
`ID_AUTH_PASS`.

## `Verified control IDs not found - falling back to positional mapping`

Informational, not an error. Control 1012 or 1219 was not found, or 1219 was not
a password field, so the older positional logic is in use. The connection can
still succeed, but the IDs should be re-checked against the current client — see
[03-win32-reference.md](03-win32-reference.md).

## `WARNING: Login screen reappeared - connection may have failed`

`Test-VpnConnected` saw the login window return more than 10 seconds after the
credentials were submitted ([AutoVPN.ps1:739](../AutoVPN.ps1)). This is the
signature of rejected credentials.

Open Settings and re-enter them. Note that credentials are stored per user and
per machine — see [06-data-reference.md](06-data-reference.md).

## `Connection verification timed out`

30 seconds elapsed without `Test-VpnConnectedNow` returning true, and the login
window did not reappear.

Check whether the VPN adapter exists and what its description is:

```powershell
Get-NetAdapter | Where-Object InterfaceDescription -like "*VPN*" | Format-Table Name, InterfaceDescription, Status
```

The detection filter matches `*VMware SSL VPN*` or `*SSL VPN-Plus*` against
`InterfaceDescription` ([AutoVPN.ps1:700](../AutoVPN.ps1)). A different adapter
description will never match, and the fallback heuristic will not help while the
login window is visible.

## `Could not stop SVPClient: <message>`

The elevated `taskkill` failed. Most commonly the user dismissed the UAC prompt,
in which case `Process.Start` throws and the UI is set back to `Connected`
([AutoVPN.ps1:1053](../AutoVPN.ps1)).

Disconnect always requires elevation, because SVPClient is protected by the
`NeoSrv` service. There is no way to avoid the prompt with the current approach.

## `VPN still connected - disconnect failed`

`taskkill` reported success but the adapter was still `Up` 15 seconds later.

Check whether `NeoSrv` restarted the client:

```powershell
Get-Process SVPClient -ErrorAction SilentlyContinue
Get-Service NeoSrv
```

## Status is wrong: shows Connected when it is not

`Test-VpnConnectedNow` has a heuristic fallback that reports connected whenever
an `SVPClient` process exists and no login window is visible
([AutoVPN.ps1:715](../AutoVPN.ps1)). It fires during the interval between the
client starting and its login dialog appearing, and whenever the adapter query
throws.

A `Connected` state that was reached without an adapter-verified log line
(`VPN Connected! (adapter verified)`) came from the heuristic and should not be
trusted. Confirm with `Get-NetAdapter`.

## The sequence stalls partway through after clicking something

This is a structural issue, not a configuration one. See
[04-background-service.md](04-background-service.md), which documents the
mechanism and the possible fixes.

This was fixed in two parts: the sequence now runs on a worker thread, and every
entry point that could re-enter it (tray items, Settings) is disabled while it
runs. If the symptom reappears, check that `Set-ActionsEnabled` still covers the
control that was clicked.

## The application freezes completely with no log output

If SVPClient raises a modal dialog in response to a click, a synchronous
`SendMessage` does not return until that dialog closes. Clicks now use
`PostMessage` and text operations use `SendMessageTimeout`, and the automation
runs on a worker thread, so even a blocking call would no longer freeze the
window. If the UI does freeze, an un-migrated `SendMessage` on the UI thread is
the first thing to look for:

```powershell
Select-String -Path AutoVPN.ps1 -Pattern '::SendMessage\('
```

## Settings do not take effect

`Load-Config` runs once, at the start of `Main` ([AutoVPN.ps1:1687](../AutoVPN.ps1)).
Editing `config.json` by hand while the application is running has no effect
until restart. Changes made through the Settings dialog are written and applied
in-process.

## Nothing happens at all when launching

Two things to check:

1. `app.bat` hardcodes `D:\SecureVPN\AutoVPN.ps1`. If the repository was cloned
   elsewhere, the launcher points at a file that does not exist and PowerShell
   exits silently because the console window is hidden.
2. The script requires STA. The entry point relaunches itself if the apartment
   state is wrong ([AutoVPN.ps1:1812](../AutoVPN.ps1)); if that relaunch loops,
   the executable-versus-script detection is misfiring.

To see the error, run without the hidden window:

```powershell
powershell -ExecutionPolicy Bypass -STA -File "D:\SecureVPN\AutoVPN.ps1"
```

Any unhandled exception in `Main` is also shown in a message box with a stack
trace ([AutoVPN.ps1:1831](../AutoVPN.ps1)).
