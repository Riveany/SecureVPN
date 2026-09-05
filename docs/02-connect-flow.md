# Connect and disconnect flows

## Connect: the seven steps

`Connect-VPN` ([AutoVPN.ps1:699](../AutoVPN.ps1)) runs a fixed seven-step
sequence. Each step logs a `Step N:` line, so the activity log maps directly
onto this document.

Before step 1, the function checks `$Script:IsConnecting` and returns early if a
connection is already running, then sets the flag and switches the UI to
`Connecting`. Credentials are loaded up front; if none exist the sequence aborts
and the user is told to open Settings.

### Step 1 — Start SVPClient

`Start-SVPClient` ([AutoVPN.ps1:347](../AutoVPN.ps1)) launches the executable at
`$Script:Config.vpn_client_path`, waits 3 seconds, then confirms a process named
`SVPClient` exists. If the process is already running, the function returns
early without launching a second copy.

Followed by a 2-second `DoEvents-Sleep`.

### Step 2 — Find the Login window

`Find-SVPLoginWindow` ([AutoVPN.ps1:374](../AutoVPN.ps1)) polls every 500 ms for
up to 15 seconds, looking for a visible window whose title contains
`SSL VPN-Plus Client - Login`.

It returns a hashtable with a `Status` of `found`, `connected`, or `timeout`.
The `connected` case exists because the VPN may already be up — the function
calls `Test-VpnConnectedNow` both before the loop and on every iteration, and
short-circuits the whole sequence if the adapter is already reporting `Up`.

### Step 3 — Click Login

`Click-LoginButton` ([AutoVPN.ps1:407](../AutoVPN.ps1)) calls
`ShowWindow(SW_RESTORE)` on the login window, waits 300 ms, then clicks control
ID **1018** via `Win32::ClickButton`.

The `ShowWindow` call is the one place in the connect flow that deliberately
changes window z-order. It is not required for `BM_CLICK` to work and is a
contributing factor to the interference described in
[04-background-service.md](04-background-service.md).

Followed by a 2-second `DoEvents-Sleep`.

### Step 4 — Handle the Security Alert

`Handle-SecurityAlert` ([AutoVPN.ps1:425](../AutoVPN.ps1)) polls for up to 10
seconds for a window titled `Security Alert`. This is the certificate-trust
dialog and does not always appear; its absence is not an error.

When found, it clicks control **1278**, the verified Yes button for this client.
If that ID is absent it falls back to matching a `Button` whose text is `&Yes` or
`Yes`, then to `GetDlgItem(hwnd, 6)` (`IDYES`). The `6` fallback is retained for
other client builds but does **not** match this one — verified by live
enumeration. If all three fail, every button found is logged with ID and text,
to make the dialog diagnosable from the log alone.

Followed by a 1-second `DoEvents-Sleep`.

### Step 5 — Find the Authentication window

`Find-AuthWindow` ([AutoVPN.ps1:492](../AutoVPN.ps1)) polls for up to 20 seconds
for a window titled `User Authentication`.

Two additional behaviours are folded into this loop:

- If a `Security Alert` appears mid-wait, it is handled and the loop `continue`s
  without incrementing the timeout counter for that iteration.
- After 10 seconds, if `Test-VpnConnectedNow` returns true, the function returns
  the sentinel value `[IntPtr](-1)`, meaning *connected without needing auth*.
  The caller checks for this explicitly.

### Step 6 — Fill the authentication form

`Fill-AuthForm` ([AutoVPN.ps1:526](../AutoVPN.ps1)) enumerates all child controls
of the auth dialog and partitions them into `Edit` and `Button` lists, logging
each one's ID and text.

It resolves the two fields by their verified control IDs — **1012** for the
username and **1219** for the password — and confirms that 1219 really carries
the `ES_PASSWORD` style before using it.

If those IDs are absent it falls back to the older positional mapping (first
`Edit` is username, second is password), but only after the same `ES_PASSWORD`
check passes. If the field that would receive the password does not mask input,
the function aborts rather than typing the password into a visible box.

Text is set with `WM_SETTEXT` via `SendMessageTimeout`, 200 ms apart.

The OK button is control **1**, clicked directly when present; otherwise the
older text match against `OK|Login|Submit|Connect` applies. Clicks are posted
with `PostMessage` so a modal dialog cannot hang the caller.

Immediately after this call returns, the caller nulls the password and
credential variables and invokes `[System.GC]::Collect()` to shorten the window
during which the plaintext password is resident in memory.

### Step 7 — Verify

After a 3-second `DoEvents-Sleep`, `Test-VpnConnected`
([AutoVPN.ps1:635](../AutoVPN.ps1)) polls for up to 30 seconds. It succeeds as
soon as `Test-VpnConnectedNow` returns true. It fails early if the Login window
reappears after the first 10 seconds, which indicates rejected credentials.

On success the UI switches to `Connected`, `Dismiss-SVPNotification` clears the
client's own "connection established" popup, and a tray balloon is shown.

On failure the notification is still dismissed, the UI returns to
`Disconnected`, and the log advises checking SVPClient directly.

The `finally` block clears `$Script:IsConnecting` on every path, including
exceptions.

## How connection state is detected

`Test-VpnConnectedNow` ([AutoVPN.ps1:608](../AutoVPN.ps1)) is the single source
of truth for "is the VPN up", and it is called from many places. It uses two
checks in order:

1. **Adapter check (authoritative).** `Get-NetAdapter` filtered on
   `InterfaceDescription` matching `*VMware SSL VPN*` or `*SSL VPN-Plus*`, then
   tests `Status -eq "Up"`.

2. **Heuristic fallback.** If the adapter query throws or matches nothing: if an
   `SVPClient` process exists *and* no window titled
   `SSL VPN-Plus Client - Login` is visible, assume connected.

The fallback is a guess, not a measurement. It will report connected during the
window between the client starting and its login dialog becoming visible. Treat
a `Connected` status that was not preceded by an adapter-verified log line with
suspicion.

## Disconnect

`Disconnect-VPN` ([AutoVPN.ps1:833](../AutoVPN.ps1)) does not use the client's
own disconnect button. It kills the process.

The reason is stated in a comment at [AutoVPN.ps1:840](../AutoVPN.ps1):
`SVPClient` is protected by the `NeoSrv` service and cannot be terminated
without elevation.

The sequence is:

1. Return early if `Test-VpnConnectedNow` is already false.
2. Build a `ProcessStartInfo` for `cmd.exe /c taskkill /F /IM SVPClient.exe`
   with `Verb = "runas"`, which triggers a UAC prompt.
3. `WaitForExit(10000)`.
4. Poll the adapter once per second for up to 15 seconds, waiting for it to stop
   reporting `Up`.
5. Update the UI and show a tray balloon.

If the user cancels the UAC prompt, `Process.Start` throws, the exception is
caught, the log records the failure, and the UI is set back to `Connected`.

Two consequences worth knowing:

- **Disconnect always requires an administrator prompt.** This is the reason the
  README lists administrator privileges as a requirement for disconnect only.
- **`Disconnect-VPN` has no re-entrancy guard.** Unlike `Connect-VPN`, nothing
  prevents it from being invoked while a connection is in progress. See
  [04-background-service.md](04-background-service.md).

## Sequence at a glance

```
Connect-VPN
  ├─ guard: $Script:IsConnecting
  ├─ Load-VpnCredential ──────────── abort if absent
  ├─ 1. Start-SVPClient              (3 s wait, verify process)
  ├─ 2. Find-SVPLoginWindow          (poll 15 s) ─── may short-circuit to Connected
  ├─ 3. Click-LoginButton            (ShowWindow + BM_CLICK id 1018)
  ├─ 4. Handle-SecurityAlert         (poll 10 s, optional dialog)
  ├─ 5. Find-AuthWindow              (poll 20 s) ─── may return -1 = already connected
  ├─ 6. Fill-AuthForm                (WM_SETTEXT ×2, BM_CLICK OK)
  ├─ 7. Test-VpnConnected            (poll 30 s, adapter)
  │     └─ Dismiss-SVPNotification
  └─ finally: clear $Script:IsConnecting
```
