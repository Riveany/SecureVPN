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
inside `DoEvents-Sleep` ([AutoVPN.ps1:723](../AutoVPN.ps1)), which is invoked
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
([AutoVPN.ps1:1100](../AutoVPN.ps1)), so even a routine status update inside the
sequence is a re-entrancy point.

## Cause 2 — the guards cover the buttons but not the tray (FIXED)

> Resolved. Recorded here because it explains the reported symptom and the
> shape of the fix.

The main window's Connect and Disconnect buttons were already protected:
`Update-UIState "Connecting"` disables both, and `$Script:IsConnecting` blocked a
second `Connect-VPN`.

Three entry points were not covered, because `ContextMenuStrip` items carry
their own `Enabled` property and were never touched by `Update-UIState`:

| Entry point | Was | Now |
|---|---|---|
| Tray → Connect VPN | `$Script:IsConnecting` only | Disabled for the whole sequence |
| Tray → Disconnect | **unguarded** — killed the client mid-connect | Cancels the connect, then disconnects |
| Settings button / tray → Settings | **unguarded**, and modal | Disabled; `Show-SettingsDialog` also refuses to open |

`Set-ActionsEnabled` now gates all four controls, and `Show-SettingsDialog`
returns early if a sequence is running, so the modal can no longer freeze a
connect mid-step.

### Cancellation

`$Script:CancelRequested` is checked by `Test-Cancelled` at the top of every
polling loop and between connect steps, and `DoEvents-Sleep` returns early when
it is set. A cancel therefore takes effect at the next poll — measured at
**0.1 s** — rather than after the current step's timeout, which for step 5 was
up to 20 seconds.

### The deadlock this created, and why the fix is shaped as it is

The first implementation had `Disconnect-VPN` set the cancel flag and then wait
for `$Script:IsConnecting` to clear. That deadlocks, and testing caught it.

The tray handler runs *inside the connect sequence's own message pump*, so
`Connect-VPN` is still on the stack below it. `Connect-VPN` can only clear the
flag by returning, and it cannot return until the handler does. The wait expired
after 10 seconds and the disconnect was silently discarded — worse than the
original bug.

The working shape: `Disconnect-VPN` sets `$Script:CancelRequested` and
`$Script:DisconnectAfterCancel`, then **returns immediately**. `Connect-VPN`
sees the cancel, unwinds, and its `finally` block invokes the disconnect on a
clean stack. The two sequences can never be on the stack at once.

Verified live: cancel at step 4 unwound in 0.1 s, the disconnect then ran to
completion, and both flags were clear afterwards.

## Options for background operation

### Option A — move the sequence to a background runspace (NOT DONE)

Run the connect and disconnect sequences on a separate PowerShell runspace and
marshal status updates back to the UI thread via `Control.Invoke`.

**This has not been implemented, and is no longer the first thing to reach for.**
The guard-and-cancel work above closes the re-entrancy that caused the reported
symptom, and the `SendMessageTimeout`/`PostMessage` change removed the only way a
single Win32 call could block the thread. What remains on the UI thread is
`Start-Sleep` in 100 ms slices between `DoEvents()` calls.

It would still be required to run the connect flow with no window at all, and it
is a prerequisite for any headless mode. If it is done later it needs:

- a runspace with the `Win32` type and the automation functions available;
- thread-safe `Write-Log` and `Update-UIState` that marshal every control touch
  through `Invoke`, since Windows Forms controls may only be touched from the
  thread that created them;
- the same cancellation plumbing that already exists — `$Script:CancelRequested`
  and the deferred-disconnect handoff carry over unchanged.

Note that the UAC elevation in `Disconnect-VPN` behaves the same on a worker
thread: the prompt is raised by the OS against the process, not the thread.

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
shortcut created by `Set-AutoStart` ([AutoVPN.ps1:1300](../AutoVPN.ps1)) with
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

The reported symptom is fixed by the guard-and-cancel work described under
Cause 2, not by any of these options.

Option C remains a worthwhile addition — it removes the window that invites the
stray click in the first place. Option A is only needed for a genuinely headless
mode. Options B and D are ruled out and recorded so they are not
re-investigated: B is blocked by session 0 isolation, D by gateway policy.

## Smaller changes

Done:

- **Tray menu items and the Settings button are gated** by `Set-ActionsEnabled`
  during any sequence, and `Show-SettingsDialog` refuses to open on top of one.
- **`Disconnect-VPN` has a re-entrancy guard** (`$Script:IsDisconnecting`) and
  defers to `Connect-VPN`'s unwind rather than racing it.
- **`SendMessage` replaced** by `PostMessage` for clicks and
  `SendMessageTimeout` for text — see
  [03-win32-reference.md](03-win32-reference.md).
- **Verified control IDs 1012 and 1219** used in `Fill-AuthForm`, with an
  `ES_PASSWORD` check that aborts rather than typing the password into a
  visible field.

Still open:

- **Drop the `ShowWindow(SW_RESTORE)` in `Click-LoginButton`** (cause 3).
  `BM_CLICK` does not need it, and it pulls the client's window forward for no
  benefit. Verify against the client before removing.

## Verifying a fix

The original failure is reproduced by starting a connection and selecting
**Disconnect from the tray menu** during step 5, while the log shows
`Waiting for Authentication window...`.

Before the fix, the log showed the disconnect completing, then step 5 continuing
to poll a process that no longer existed, timing out after 20 seconds, and
overwriting the UI state the disconnect had just set.

After the fix the same action produces one coherent outcome:

```
[..] Step 4: Checking for Security Alert...
[..] Cancelling connect in progress...
[..] Cancel requested - stopping connect sequence
[..] Connect sequence cancelled
[..] Proceeding with requested disconnect...
[..] Disconnecting VPN...
```

`Connect-VPN` returns 0.1 s after the cancel, and both `$Script:IsConnecting`
and `$Script:IsDisconnecting` are false afterwards.

The intermediate deadlock is worth re-testing if this code is changed: if
`Disconnect-VPN` ever waits for `$Script:IsConnecting` to clear instead of
deferring, the log will show `Connect sequence did not stop in time` and the
user's request will be discarded.
