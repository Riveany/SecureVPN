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

## Cause 1 — the sequence ran on the UI thread and pumped the message loop (FIXED)

This was the primary cause, and it is the one the runspace work removed.

`Connect-VPN` used to run on the same thread as the Windows Forms message loop.
To keep the window from freezing during its long waits it called
`[System.Windows.Forms.Application]::DoEvents()` — between steps, inside
`DoEvents-Sleep`, and at the end of `Update-UIState`.

`DoEvents()` dispatches all pending Windows messages, **including user input**.
So a click on any enabled control while the sequence was waiting ran that
control's handler *nested inside* the paused `Connect-VPN` call — a re-entrant
call on the same stack.

Concretely: while step 5 polled for the authentication window, selecting
Disconnect from the tray ran `Disconnect-VPN` on that same stack. It killed
`SVPClient.exe`, waited for the adapter to drop, set the UI to `Disconnected`,
and returned — whereupon step 5 resumed, kept polling for a window belonging to
a process that no longer existed, timed out 20 seconds later, and overwrote the
state the disconnect had just set.

**Fixed** by moving the sequence to a worker thread (Option A below). The UI
thread is no longer inside the sequence, so it has nothing to pump: there are now
zero `DoEvents()` calls in the file. `DoEvents-Sleep` keeps its name but is now a
plain sleep that returns early on cancel.

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

## Cause 3 — the flow raised the SVPClient window (FIXED)

`Click-LoginButton` called `ShowWindow(SW_RESTORE)` on the login window before
clicking it, with a 300 ms wait.

`BM_CLICK` never needed this. The call restored a minimised window and pulled it
forward, which meant the connect sequence visibly disturbed whatever the user was
doing — and put a clickable window on screen at exactly the moment cause 1 made
stray clicks dangerous.

Removed, after verifying the click works without it: with the login window
deliberately minimised (`SW_MINIMIZE`, `IsIconic` confirmed true), `BM_CLICK` on
control 1018 still reached the client and the Security Alert appeared. The
foreground window handle was identical before and after. A full seven-step
connect then ran to completion with the window minimised throughout.

The automation now never restores, raises, or focuses an SVPClient window.

## Options for background operation

### Option A — move the sequence to a background runspace (DONE)

The connect and disconnect sequences run on a worker thread. The UI thread
returns to its normal message loop immediately after the button click and is
never blocked, so nothing needs `DoEvents()` — there are now **zero** calls to
it anywhere in the file, which removes the mechanism behind cause 1 entirely.

**Shape of the implementation**

`Connect-VPN` and `Disconnect-VPN` are thin dispatchers. The work itself lives in
`Connect-VPNCore` and `Disconnect-VPNCore`, which are thread-agnostic.
`Start-VpnWorker` runs one of them on a shared runspace and starts a UI-thread
timer that reaps the worker when it finishes, surfacing any error into the log
rather than losing it on a thread nobody is watching.

**Two things had to be verified rather than assumed**

*A new runspace does not inherit this script's functions.* Calling one from the
worker fails with "not recognized as the name of a cmdlet". So `Main` bootstraps
the runspace by feeding it every relevant function definition from
`Get-ChildItem Function:` before any work is dispatched.

*A separate runspace does not share `$Script:` variables either.* The
cancellation flags therefore live in `$Script:Shared`, a
`[hashtable]::Synchronized(@{...})` handed to the worker as the same object
instance both threads hold. Setting `Cancel` on one thread is seen by the other
at its next check.

**UI access from the worker**

Windows Forms controls may only be touched from the thread that created them, so
`Write-Log`, `Update-UIState`, `Set-ActionsEnabled` and `Show-Balloon` all
marshal through `Invoke-OnUI`, which uses `Control.Invoke`.

One subtlety cost a debugging round and is worth recording: **a `$Script:`
reference inside a marshalled script block resolves against the UI thread's
scope, not the worker's.** The worker's `$Script:LogBox` is not the UI thread's,
so the block silently wrote to `$null`. Every marshalled block therefore captures
the control into a **local** first, and uses `.GetNewClosure()` so the closure
carries it across:

```powershell
$box = $Script:LogBox            # capture BEFORE building the closure
Invoke-OnUI { $box.AppendText(...) }.GetNewClosure()
```

**Measured**

UI-loop iterations observed while a worker ran a full connect: **444 over
24.5 s**. The same measurement against the old design would be approximately
zero, because the UI thread was inside the sequence. Cross-thread cancellation
was verified separately: the UI thread set the flag and the worker unwound.

The UAC elevation in `Disconnect-VPNCore` behaves the same on a worker thread —
the prompt is raised by the OS against the process, not the thread.

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
shortcut created by `Set-AutoStart` ([AutoVPN.ps1:1449](../AutoVPN.ps1)) with
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

Options A and C are both implemented — A moves the work off the UI thread, and
the guards under Cause 2 close the re-entrancy that made stray clicks dangerous
in the first place. Together they fix the reported symptom.

Option C (a hidden logon task) remains available and is the natural next step if
the window itself should stop appearing. Options B and D are ruled out and
recorded so they are not re-investigated: B is blocked by session 0 isolation,
D by gateway policy.

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

- **`ShowWindow(SW_RESTORE)` removed from `Click-LoginButton`** (cause 3 above).
  Verified first: with the login window deliberately minimised, `BM_CLICK` still
  reached it and the Security Alert appeared, with the foreground window
  unchanged. The automation now never restores or raises an SVPClient window.

Nothing outstanding from this list.

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
