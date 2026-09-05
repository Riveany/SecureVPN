# Running unattended: why it stalls, and what can be done

This document answers the question that motivated the knowledge base: the
automation sometimes stops partway through when the user clicks something, and
it would be preferable for it to run as a background service.

## The symptom

During a connection sequence, clicking on the AutoVPN window — or on another
application — can leave the sequence stalled or produce an inconsistent state.
The log stops advancing, or shows a step failing that normally succeeds.

## The cause is not the mouse

A reasonable first hypothesis is that the automation depends on the user's mouse
pointer or on keyboard focus, so moving either one breaks it. **That is not the
case here.**

There is no `SetCursorPos`, no `mouse_event`, no `SendInput`, and no `SendKeys`
anywhere in `AutoVPN.ps1`. Every interaction with SVPClient is a window message
posted straight to a control handle — see
[03-win32-reference.md](03-win32-reference.md). `BM_CLICK` and `WM_SETTEXT`
reach their target regardless of which window has focus.

The real cause is the threading model, and there are three distinct
contributors.

## Cause 1 — the sequence runs on the UI thread and pumps the message loop

This is the primary one.

`Connect-VPN` runs on the same thread as the Windows Forms message loop. To keep
the window responsive during its long waits, it repeatedly calls
`[System.Windows.Forms.Application]::DoEvents()` — directly between steps, and
inside `DoEvents-Sleep` ([AutoVPN.ps1:690](../AutoVPN.ps1)), which is invoked
from 23 places including every polling loop.

`DoEvents()` dispatches all pending Windows messages. That includes user input.
So a click on any AutoVPN control while the connect sequence is waiting causes
that control's event handler to run **nested inside** the paused `Connect-VPN`
call — a re-entrant call on the same stack.

Concretely: while step 5 is polling for the authentication window, a click on a
tray-menu item enters that item's handler on the same stack. Selecting
**Disconnect** from the tray runs `Disconnect-VPN`, which kills `SVPClient.exe`,
waits for the adapter to drop, sets the UI to `Disconnected`, and returns.
Control then resumes inside step 5, which continues polling for an
authentication window belonging to a process that no longer exists — until its
20-second timeout elapses, at which point it reports an error and overwrites the
UI state that `Disconnect-VPN` just set.

`Update-UIState` itself ends with a `DoEvents()` call
([AutoVPN.ps1:959](../AutoVPN.ps1)), so even a routine status update inside the
sequence is a re-entrancy point.

## Cause 2 — the guards cover the buttons but not the tray

The main window's Connect and Disconnect buttons are, in fact, already protected.
`Update-UIState "Connecting"` disables both ([AutoVPN.ps1:936](../AutoVPN.ps1)),
and `Connect-VPN` sets that state before doing any work. A double-click on
Connect is additionally blocked by `$Script:IsConnecting`
([AutoVPN.ps1:700](../AutoVPN.ps1)).

Three entry points are **not** covered:

| Entry point | Location | Guard |
|---|---|---|
| Tray menu → Connect VPN | [AutoVPN.ps1:1320](../AutoVPN.ps1) | `$Script:IsConnecting` only — logs and returns |
| Tray menu → Disconnect | [AutoVPN.ps1:1326](../AutoVPN.ps1) | **none** — runs the full disconnect mid-connect |
| Settings button / tray → Settings | [AutoVPN.ps1:1280](../AutoVPN.ps1), [1240](../AutoVPN.ps1) | **none** — the button is never disabled, and the dialog is modal |

`ContextMenuStrip` items have their own `Enabled` property and are never touched
by `Update-UIState`, so disabling the form's buttons does nothing for them.

The tray Disconnect item is the damaging one: `Disconnect-VPN`
([AutoVPN.ps1:833](../AutoVPN.ps1)) has no re-entrancy guard of any kind, and it
kills the process the in-flight connect sequence is still driving.

The Settings path is subtler. `Show-SettingsDialog` is modal, so the nested call
does not return until the dialog is dismissed — the connect sequence is frozen
mid-step for as long as the dialog is open, while its timeouts continue to be
measured against the wall clock in the polling loops that use
`[System.Diagnostics.Stopwatch]`.

## Options for background operation

### Option A — move the sequence to a background runspace

Run the connect and disconnect sequences on a separate PowerShell runspace and
marshal only status updates back to the UI thread via `Control.Invoke`.

This eliminates cause 1 outright. The UI thread returns to its normal message
loop immediately after the button click, so it stays responsive without any
`DoEvents()` calls, and no user input can re-enter the sequence. `DoEvents-Sleep`
becomes a plain `Start-Sleep` on the worker thread.

What it requires:

- A runspace with the `Win32` type and the automation functions available to it.
- Replacing `Write-Log` and `Update-UIState` with thread-safe versions that
  marshal to the UI thread — every touch of `$Script:LogBox`, `$Script:StatusLabel`,
  and the buttons must go through `Invoke`, because Windows Forms controls may
  only be touched from the thread that created them.
- A cancellation mechanism, so that a Disconnect request during a connection
  stops the worker rather than racing it.
- Deciding what the Disconnect button does mid-connect: cancel the worker and
  then disconnect, or refuse until the worker finishes.

Note that the UAC elevation in `Disconnect-VPN` behaves the same on a worker
thread — the prompt is raised by the OS against the process, not the thread.

This is the option that addresses the reported problem.

### Option B — a Windows service running as SYSTEM

**This does not work, and the reason is a constraint of the VMware client, not
of this project.**

A Windows service runs in session 0, which has its own window station and
desktop, isolated from the interactive user session since Windows Vista. SVPClient
is a GUI application whose dialogs are created on the interactive desktop. A
process in session 0 cannot enumerate those windows, cannot obtain their handles,
and therefore cannot send them messages. `EnumWindows` from session 0 simply will
not see them.

Workarounds that are sometimes proposed for this — the `Interactive Services
Detection` service, or `CreateProcessAsUser` with an explicit session ID — are
either removed from current Windows versions or amount to launching the client
back into the interactive session, which is what the current design already does.

Unless a command-line or API-driven connection method for the VMware client is
identified, a true SYSTEM service is not achievable. That would be a different
integration entirely, not a refactor of this one.

### Option C — a hidden scheduled task at user logon

Register a scheduled task that runs at logon under the user's own account, with
`Run whether user is logged on or not` left off, `Hidden` set, and the AutoVPN
window suppressed or started directly to the tray.

This runs in the interactive session, so window automation works. It removes the
visible window that invites the stray click, and it replaces the Startup-folder
shortcut created by `Set-AutoStart` ([AutoVPN.ps1:1151](../AutoVPN.ps1)) with
something more controllable.

It is a mitigation, not a fix. The re-entrancy in cause 1 is still present; there
is simply less opportunity to trigger it. Interacting with the tray menu during a
connection would still re-enter the sequence.

### Option D — let the client log in by itself (RULED OUT)

The client has a built-in credential-storage feature. If it could be enabled,
step 5 and step 6 of the connect flow would disappear entirely, along with
`vpn_cred.dat`, the whole DPAPI credential region, and the plaintext-password
exposure described in [06-data-reference.md](06-data-reference.md).

**It is disabled by the gateway and cannot be enabled from the client.**

Investigated on 2026-09-05 against SVPClient v6.3.0 and gateway `ADA-VPN`:

| Where | Finding |
|---|---|
| `SVPClient.exe` strings | Contains `&Remember password`, `Remember Username`, `&Disable Silent Mode`, `&Don't login silently next time`, `AUTORECONNECT` — the feature exists in the binary |
| Registry `HKCU\...\Connection #1` | `RemUser = 1` (username is remembered), `LocalStore = 0` (password is **not** stored), `DontLoginSilentlyOnce = 0` |
| Login window | No checkbox controls of any kind |
| Settings dialog | Only `Remember Username` (1305, checked); no password option |
| **Auth dialog** | Control **1218**, `&Remember password`, class `Button`, style `CHECKBOX` — present but **`enabled=False`, `visible=False`** |

The checkbox is created by the client and then disabled and hidden. That is the
signature of a server-side policy: the gateway tells the client not to offer
credential storage. Setting `LocalStore = 1` in the registry by hand does not
help, because the client re-applies the gateway's policy on each connection.

Enabling this would require a change on the gateway by whoever administers it.
Until then, `Fill-AuthForm` cannot be removed.

One adjacent observation: Settings contains a hidden checkbox 1304, `Start
client before Windows Logon for certificate authentication only`. If the gateway
supported certificate authentication and a client certificate were installed,
that path would need no typed credentials at all. It is hidden in the current
setup, which suggests certificate auth is not configured here.

### Recommendation

Option A is the fix. Option C is a worthwhile addition on top of it. Options B
and D are both ruled out and are recorded here so they are not re-investigated:
B is blocked by session 0 isolation, D by gateway policy.

## Smaller changes worth making regardless

These are independent of which option is chosen:

- **Disable the tray menu items during a sequence.** This is the largest gap and
  the cheapest to close. `Update-UIState` already owns enablement for the form's
  buttons; extending it to hold references to `$trayConnect`, `$trayDisconnect`,
  and `$traySettings` and set their `Enabled` alongside would remove the
  most damaging re-entrancy path before any threading work is done.
- **Disable the Settings button** in the `Connecting` and `Disconnecting` states,
  for the same reason. It is currently a local variable in `Build-MainForm`
  ([AutoVPN.ps1:1272](../AutoVPN.ps1)) and would need to be promoted to
  `$Script:` scope to be reachable from `Update-UIState`.
- **Add a re-entrancy guard to `Disconnect-VPN`** mirroring
  `$Script:IsConnecting`, so it is defended even if a new entry point is added
  later.
- **Drop the `ShowWindow(SW_RESTORE)` in `Click-LoginButton`** (cause 3).
  `BM_CLICK` does not need it. Verify against the client before removing.
- **Replace `SendMessage` with `PostMessage` for clicks and
  `SendMessageTimeout` for text reads.** `SendMessage` does not return while the
  target is showing a modal dialog; on the UI thread that freezes the whole
  application with no timeout. This was reproduced against the Settings button —
  see [03-win32-reference.md](03-win32-reference.md).
- **Use the verified control IDs 1012 and 1219** in `Fill-AuthForm` instead of
  mapping the two `Edit` controls by position.

## Verifying a fix

To confirm the interference is gone, reproduce it deliberately first: start a
connection and click Disconnect during step 5, when the log shows
`Waiting for Authentication window...`. On the current code the log will show
the disconnect completing, then step 5 continuing to poll and eventually timing
out, with the final UI state coming from the connect sequence rather than the
disconnect.

After a fix, the same action should produce exactly one coherent outcome and one
final UI state.
