# Architecture

## What the program is

`AutoVPN.ps1` is a single-file PowerShell application, roughly 2,000 lines,
that hosts a Windows Forms GUI and automates a third-party GUI application
(`SVPClient.exe`, the VMware SSL VPN-Plus Client). It is launched through
[`app.bat`](../app.bat), which runs PowerShell with `-STA -WindowStyle Hidden`,
or as a compiled executable produced by [`build.bat`](../build.bat).

There is no service and no separate process: the GUI and the automation live in
one process. They do not share a thread, though — the automation runs on a worker
runspace, which is what keeps a stray click from corrupting an in-flight
sequence. See [04-background-service.md](04-background-service.md).

## Region map

The script is divided into eleven numbered regions. This is the fastest way to
navigate it.

| Region | Lines | Responsibility |
|---|---|---|
| `[1] Assembly & Type Loading` | 22–232 | Loads Windows Forms and Drawing; compiles the inline C# `Win32` helper class |
| `[2] Global Variables` | 234–289 | Script directory detection, `$Script:`-scoped state, the worker handles, and `$Script:Shared` |
| `[3] Config Management` | 291–323 | Loads, creates, and saves `config.json`; resolves the credential file path |
| `[4] Credential Management` | 325–374 | DPAPI encrypt/decrypt of the VPN username and password |
| `[5] Logging` | 376–440 | `Invoke-OnUI` (the UI-thread marshaller) and `Write-Log` |
| `[6] VPN Automation Engine` | 438–1227 | The connect and disconnect cores, their helpers, the cancellation checks, and the worker dispatchers |
| `[7] UI State Management` | 1229–1267 | `Update-UIState` — the single place that sets status text, colour, and button enablement |
| `[8] Settings Dialog` | 1269–1475 | Modal dialog for credentials, connection name, auto-connect, auto-start, and tray behaviour |
| `[9] Auto-Start Management` | 1477–1607 | `Get-AutoStartCommand`, `Test-AutoStart`, `Set-AutoStart` — the hidden logon task |
| `[10] Main GUI` | 1609–1817 | `Build-MainForm` — the dark-themed form, tray icon, and event handlers |
| `[11] Main Entry Point` | 1819–end | `Main`, the worker runspace setup, the STA guard, and the top-level `try`/`catch` |

The script now opens with a `param([switch]$Background)` block before region 1;
a `param()` must be the first statement in a file, so it sits above the banner
comment's usual position.

The automation engine holds both the thread-agnostic work (`Connect-VPNCore`,
`Disconnect-VPNCore`) and the dispatchers that run it on the worker
(`Start-VpnWorker`, `Connect-VPN`, `Disconnect-VPN`).

## Threading model

This is the most important section in this document.

The application has **two threads**: the Windows Forms UI thread, and a worker
that runs the VPN automation.

`Main` ends with `[System.Windows.Forms.Application]::Run($form)`
([AutoVPN.ps1:1996](../AutoVPN.ps1)), which starts the message loop on the UI
thread. Before that it creates `$Script:WorkerRunspace` — an STA runspace that
every connect and disconnect runs on.

### Why a separate runspace needs bootstrapping

A new runspace starts empty. It inherits neither this script's functions nor its
`$Script:` variables — both verified, not assumed. `Main` therefore:

1. Feeds the runspace every relevant function definition from
   `Get-ChildItem Function:`.
2. Binds the config, script directory, form handle, and control references into
   the worker's own `$Script:` scope.
3. Hands it `$Script:Shared`, a `[hashtable]::Synchronized(@{...})` that is the
   **same object instance** on both threads. This is the entire channel between
   them: `Cancel`, `DisconnectAfterCancel`, `IsConnecting`, `IsDisconnecting`.

### Dispatch

`Connect-VPN` and `Disconnect-VPN` are thin dispatchers that validate state and
call `Start-VpnWorker`. The work lives in `Connect-VPNCore` and
`Disconnect-VPNCore`. A UI-thread timer polls for worker completion, disposes it,
surfaces any errors into the log, and starts the deferred disconnect if one was
requested mid-connect.

### Touching the UI from the worker

Windows Forms controls may only be touched from the thread that created them.
`Write-Log`, `Update-UIState`, `Set-ActionsEnabled` and `Show-Balloon` therefore
marshal through `Invoke-OnUI`, which calls `Control.Invoke`.

**A `$Script:` reference inside a marshalled block resolves against the UI
thread's scope, not the worker's.** Each of those functions captures the control
into a local first and builds the block with `.GetNewClosure()`, so the closure
carries the reference across the boundary:

```powershell
$box = $Script:LogBox            # capture BEFORE building the closure
Invoke-OnUI { $box.AppendText("$line`r`n") }.GetNewClosure()
```

Without the local, the block writes to `$null` silently.

### No DoEvents anywhere

The file previously called `Application::DoEvents()` in ten places to keep the
window alive while the UI thread was busy. All are gone: the UI thread is never
busy. That removes the re-entrancy documented in
[04-background-service.md](04-background-service.md).

## State

UI-thread state is `$Script:`-scoped, declared in region 2:

| Variable | Purpose |
|---|---|
| `$Script:ScriptDir` | Directory containing the script or executable; base for all relative paths |
| `$Script:ConfigPath`, `$Script:Config` | Path to and parsed contents of `config.json` |
| `$Script:MainForm` | The main window; also the object `Invoke-OnUI` marshals through |
| `$Script:LogBox` | Read-only multiline TextBox that `Write-Log` appends to |
| `$Script:StatusLabel`, `$Script:StatusIcon` | Status text and the coloured dot beside it |
| `$Script:ConnectBtn`, `$Script:DisconnectBtn` | Buttons whose enablement `Update-UIState` controls |
| `$Script:SettingsBtn`, `$Script:TrayConnect`, `$Script:TrayDisconnect`, `$Script:TraySettings` | The entry points `Update-UIState` cannot reach; gated by `Set-ActionsEnabled` |
| `$Script:TrayIcon` | NotifyIcon used for balloon notifications |
| `$Script:Worker`, `$Script:WorkerHandle`, `$Script:WorkerRunspace`, `$Script:WorkerPoll` | The background worker and the timer that reaps it |

### Cross-thread state

Everything both threads must see lives in `$Script:Shared`, a
`[hashtable]::Synchronized(@{...})`. It is the same object instance in both
runspaces — that is the whole channel between them.

| Key | Meaning |
|---|---|
| `Cancel` | Set to abandon a running connect. Checked by `Test-Cancelled` at every polling loop and between steps; `DoEvents-Sleep` returns early on it. |
| `DisconnectAfterCancel` | A disconnect was requested mid-connect. The worker-reaper timer starts it once the connect worker has been disposed. |
| `IsConnecting` | A connect is running. Blocks a second one. |
| `IsDisconnecting` | A disconnect is running. Blocks a second one. |

A plain `$Script:` variable would **not** work here: the worker runspace has its
own scope, so each thread would be reading and writing a different variable.

Guarding happens at three levels: these flags, button enablement via
`Update-UIState`, and `Set-ActionsEnabled` for the tray items and Settings
button that `Update-UIState` cannot reach.

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
the correct flag and exits ([AutoVPN.ps1:2000](../AutoVPN.ps1)). The relaunch
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
