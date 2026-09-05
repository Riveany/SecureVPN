# Architecture

## What the program is

`AutoVPN.ps1` is a single-file PowerShell application, roughly 1,400 lines,
that hosts a Windows Forms GUI and automates a third-party GUI application
(`SVPClient.exe`, the VMware SSL VPN-Plus Client). It is launched through
[`app.bat`](../app.bat), which runs PowerShell with `-STA -WindowStyle Hidden`,
or as a compiled executable produced by [`build.bat`](../build.bat).

There is no service, no daemon, and no separate worker process. Everything —
the GUI, the automation sequence, and the status polling — runs inside one
process, on one thread. That single fact explains most of the behaviour
documented in [04-background-service.md](04-background-service.md).

## Region map

The script is divided into eleven numbered regions. This is the fastest way to
navigate it.

| Region | Lines | Responsibility |
|---|---|---|
| `[1] Assembly & Type Loading` | 9–157 | Loads Windows Forms and Drawing; compiles the inline C# `Win32` helper class |
| `[2] Global Variables` | 159–179 | Resolves the script directory (differs for `.ps1` vs compiled `.exe`) and declares all `$Script:`-scoped state |
| `[3] Config Management` | 181–213 | Loads, creates, and saves `config.json`; resolves the credential file path |
| `[4] Credential Management` | 215–264 | DPAPI encrypt/decrypt of the VPN username and password |
| `[5] Logging` | 266–286 | `Write-Log` — appends a timestamped line to the GUI log box and writes a coloured copy to the console |
| `[6] VPN Automation Engine` | 287–817 | The connect and disconnect sequences and every helper they call |
| `[7] UI State Management` | 819–873 | `Update-UIState` — the single place that mutates status label, icon colour, and button enablement |
| `[8] Settings Dialog` | 874–1057 | Modal dialog for credentials, connection name, auto-connect, and auto-start |
| `[9] Auto-Start Management` | 1058–1085 | Creates or removes a shortcut to `app.bat` in the user's Startup folder |
| `[10] Main GUI` | 1086–1280 | `Build-MainForm` — constructs the dark-themed form, tray icon, and event handlers |
| `[11] Main Entry Point` | 1281–end | `Main`, the STA guard, and the top-level `try`/`catch` |

## Threading model

This is the most important section in this document.

The application has **one thread**. `Main` ends with
`[System.Windows.Forms.Application]::Run($form)` at
[AutoVPN.ps1:1420](../AutoVPN.ps1), which starts the Windows Forms message
loop on that thread.

When you click **Connect VPN**, the button's click handler calls `Connect-VPN`
([AutoVPN.ps1:699](../AutoVPN.ps1)). That function does not return for as long
as the connection sequence takes — potentially 60 seconds or more. Because it
is running on the UI thread, the message loop is blocked for that whole time,
and the window would freeze.

To avoid the frozen window, the code pumps the message loop manually. Two
mechanisms do this:

1. Direct calls to `[System.Windows.Forms.Application]::DoEvents()` between
   steps of `Connect-VPN`.
2. `DoEvents-Sleep` ([AutoVPN.ps1:690](../AutoVPN.ps1)), a replacement for
   `Start-Sleep` that alternates `DoEvents()` with 100 ms sleeps:

   ```powershell
   function DoEvents-Sleep {
       param([int]$Milliseconds)
       $sw = [System.Diagnostics.Stopwatch]::StartNew()
       while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
           [System.Windows.Forms.Application]::DoEvents()
           Start-Sleep -Milliseconds 100
       }
   }
   ```

`DoEvents-Sleep` is called from 23 places, including inside every polling loop
in the automation engine.

`Update-UIState` also ends with a `DoEvents()` call
([AutoVPN.ps1:959](../AutoVPN.ps1)), so every status change is a pump point too.

`DoEvents()` processes all pending Windows messages, which includes **user
input events**. So while `Connect-VPN` is waiting for the authentication window
to appear, a click on any *enabled* AutoVPN control is dispatched to its handler,
and that handler runs *nested inside* the paused `Connect-VPN` call. The
consequences are described in [04-background-service.md](04-background-service.md).

## State

All mutable state is `$Script:`-scoped, declared in region 2:

| Variable | Purpose |
|---|---|
| `$Script:ScriptDir` | Directory containing the script or executable; base for all relative paths |
| `$Script:ConfigPath` | Full path to `config.json` |
| `$Script:Config` | Parsed config object |
| `$Script:MainForm` | The main window |
| `$Script:LogBox` | Read-only multiline TextBox that `Write-Log` appends to |
| `$Script:StatusLabel`, `$Script:StatusIcon` | Status text and the coloured dot beside it |
| `$Script:ConnectBtn`, `$Script:DisconnectBtn` | Buttons whose enablement `Update-UIState` controls |
| `$Script:TrayIcon` | NotifyIcon used for balloon notifications |
| `$Script:IsConnecting` | Re-entrancy guard for `Connect-VPN` |

`$Script:IsConnecting` is the only explicit concurrency control in the program.
It prevents a second `Connect-VPN` from starting while one is in progress
([AutoVPN.ps1:700](../AutoVPN.ps1)), and is cleared in a `finally` block.

Button enablement provides a second layer: `Update-UIState "Connecting"` disables
both Connect and Disconnect. Neither mechanism reaches the tray-menu items or the
Settings button, which is where re-entrancy actually gets in — see
[04-background-service.md](04-background-service.md).

## Script directory resolution

Region 2 contains a detection block that distinguishes running as a `.ps1`
from running as a PS2EXE-compiled `.exe`:

```powershell
if ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName -match '\.exe$' -and
    -not (... -match 'powershell\.exe$|pwsh\.exe$')) {
    $Script:ScriptDir = Split-Path -Parent (...MainModule.FileName)
} else {
    $Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
```

The negative check matters: when running as a script, the host process *is*
`powershell.exe`, which also ends in `.exe`. Without the second clause, a
script run would resolve its directory to the PowerShell installation folder
and fail to find `config.json`.

## STA requirement

Windows Forms requires a single-threaded apartment. The entry point checks the
current thread's apartment state and, if it is not STA, relaunches itself with
the correct flag and exits ([AutoVPN.ps1:1424](../AutoVPN.ps1)). The relaunch
path differs for script and executable, mirroring the directory detection above.

This is why [`app.bat`](../app.bat) passes `-STA` explicitly — it avoids the
relaunch entirely.

## Files on disk

| File | Committed | Purpose |
|---|---|---|
| `AutoVPN.ps1` | yes | The application |
| `app.bat` | yes | Launcher; passes `-ExecutionPolicy Bypass -STA -WindowStyle Hidden` |
| `build.bat` | yes | PS2EXE build script producing `AutoVPN.exe` |
| `AutoVPN.ico` | yes | Application icon, embedded by `build.bat` |
| `connected.ico` | untracked | Present in the working tree but not referenced by any code |
| `config.json` | no (gitignored) | Settings; auto-created on first run |
| `vpn_cred.dat` | no (gitignored) | DPAPI-encrypted credentials |
| `AutoVPN.exe` | no (gitignored) | Compiled build output; rebuild with `build.bat` |

Note that `app.bat` hardcodes the absolute path `D:\SecureVPN\AutoVPN.ps1`. The
launcher is not portable to another checkout location without editing.

See [06-data-reference.md](06-data-reference.md) for the contents and format of
the two generated files.
