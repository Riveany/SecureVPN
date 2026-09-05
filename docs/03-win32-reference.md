# Win32 automation reference

## Design principle

The project drives SVPClient by sending window messages directly to control
handles. It does not move the mouse, does not synthesise keystrokes, and does
not use `SendKeys` or `WScript.Shell.AppActivate`.

The file header states the intent at [AutoVPN.ps1:5](../AutoVPN.ps1):

> Uses Win32 Messages (GetDlgItem + SendMessage) instead of SendKeys
> for reliable, focus-independent automation.

This matters for the background-service question. Message-based automation does
not require the target window to be focused or even visible, which is exactly
what makes an unattended mode feasible. The remaining obstacle is the threading
model, not the input method — see
[04-background-service.md](04-background-service.md).

## The `Win32` class

Region 1 compiles an inline C# class via `Add-Type`. PowerShell then calls it as
`[Win32]::MethodName(...)`.

### P/Invoke declarations

| Function | Used for |
|---|---|
| `EnumWindows` | Enumerating top-level windows to find one by title |
| `GetWindowText` | Reading a window's title during enumeration |
| `IsWindowVisible` | Skipping hidden windows during enumeration |
| `GetWindowThreadProcessId` | Restricting a search to one process |
| `GetClassName` | Identifying control types (`Edit`, `Button`, `#32770`) |
| `GetDlgItem` | Fetching a control handle by dialog control ID |
| `GetDlgCtrlID` | Reading a control's ID during child enumeration |
| `IsWindowEnabled` | Checking whether a button can be clicked |
| `FindWindowEx` | Iterating child windows |
| `SendMessage` (two overloads) | Synchronous message send; the `string` overload carries `WM_SETTEXT` payloads |
| `PostMessage` | Asynchronous message post; used as the `WM_COMMAND` fallback |
| `SetForegroundWindow` | Raising the AutoVPN window itself from the tray |
| `ShowWindow` | Declared but unused — the automation never restores or raises SVPClient's windows |

### Message constants

| Constant | Value | Meaning |
|---|---|---|
| `WM_SETTEXT` | `0x000C` | Set a control's text |
| `WM_GETTEXT` | `0x000D` | Read a control's text |
| `WM_GETTEXTLENGTH` | `0x000E` | Length needed before `WM_GETTEXT` |
| `BM_CLICK` | `0x00F5` | Simulate a button click |
| `WM_COMMAND` | `0x0111` | Notification to a parent; used for the click fallback |
| `WM_CLOSE` | `0x0010` | Request a window close |
| `BN_CLICKED` | `0` | Notification code packed into the `WM_COMMAND` fallback |
| `SW_SHOW` | `5` | `ShowWindow` — show (unused) |
| `SW_RESTORE` | `9` | `ShowWindow` — restore from minimised (unused) |

### Helper methods

| Method | Behaviour |
|---|---|
| `FindWindowByTitle(string)` | Enumerates visible top-level windows; returns the first whose title contains the substring, case-insensitive. Returns `IntPtr.Zero` if none. |
| `FindWindowByPidAndTitle(uint, string)` | Same, restricted to windows owned by the given process ID. |
| `GetChildren(IntPtr)` | Walks the child chain with `FindWindowEx`, returning handle, class name, control ID, text, and enabled state for each. |
| `ClickButton(IntPtr, int)` | `GetDlgItem` for the ID, then `BM_CLICK`, with a `WM_COMMAND`/`BN_CLICKED` fallback posted to the parent. |
| `SetControlText(IntPtr, int, string)` | `GetDlgItem` then `WM_SETTEXT`. |
| `GetControlText(IntPtr)` | `WM_GETTEXTLENGTH` then `WM_GETTEXT`. |

## SVPClient window titles

These substrings are matched against window titles. They are the contract
between this project and the VMware client, and they are the most likely thing
to break on a client upgrade.

| Substring | Window |
|---|---|
| `SSL VPN-Plus Client - Login` | Main login window, shown when disconnected |
| `Security Alert` | Certificate trust dialog; optional |
| `User Authentication` | Username and password prompt |
| `SSL VPN-Plus Client` | Both the systray window when connected **and** the "connection established" notification popup |

The last entry is ambiguous by design. `Dismiss-SVPNotification`
([AutoVPN.ps1:770](../AutoVPN.ps1)) disambiguates by probing for an OK button
(`GetDlgItem` with ID 2, then ID 1) and doing nothing when neither is present.

Note also that `SSL VPN-Plus Client` is a substring of
`SSL VPN-Plus Client - Login`, so a search for the former can match the login
window. The code relies on the OK-button probe to avoid acting on the wrong one.

## Control IDs

Declared as constants at [AutoVPN.ps1:88](../AutoVPN.ps1). The login-window and
systray values were determined by enumeration against SVPClient v6.3.0.

The `Security Alert` and `User Authentication` values below were captured by
live enumeration on 2026-09-05 against the same client build (file dates
2017-11-08) and gateway `ADA-VPN`. They are **not** currently declared as
constants — the code finds those controls by text matching or position instead.
See "Verified dialog IDs" below.

### Login window

| Constant | ID | Control |
|---|---|---|
| `ID_LOGIN_BTN` | 1018 | Login button — clicked in step 3 |
| `ID_CLOSE_BTN` | 1109 | Close |
| `ID_SETTINGS_BTN` | 1229 | Settings |
| `ID_DETAILS_BTN` | 1058 | Details |
| `ID_NETWORK_COMBO` | 1047 | Network selection combo box |
| `ID_PROGRESS_BAR` | 1226 | Progress bar |

Verified present and enabled. The login window contains **no checkbox controls
at all** — only the four buttons above, the network combo, a hidden ListBox
(1044), a hidden Button (1110), static labels, and the progress bar.

### Systray window (connected state)

| Constant | ID | Control |
|---|---|---|
| `ID_SYSTRAY_CANCEL_BTN` | 1016 | `&Cancel` — the client's own disconnect |
| `ID_SYSTRAY_LOGIN_BTN` | 1018 | `&Login` — disabled while connected |

`ID_SYSTRAY_CANCEL_BTN` is declared but never used. The disconnect path kills
the process instead, for the elevation reason described in
[02-connect-flow.md](02-connect-flow.md). Whether clicking 1016 would achieve a
clean disconnect without elevation has not been tested.

### Verified dialog IDs

These were measured directly and matter because the code currently reaches these
controls by less reliable means.

**`Security Alert`** (title matches exactly):

| ID | Control |
|---|---|
| **1278** | `&Yes` |
| 1279 | `&No` |
| 1079 | `&View Certificate` |
| 1281, 1285, 1286, 1287, 1288 | Static text describing the certificate problems |

`Handle-SecurityAlert` ([AutoVPN.ps1:522](../AutoVPN.ps1)) matches on the button
**text** `&Yes`/`Yes`, which works. Its documented fallback of
`GetDlgItem(hwnd, 6)` (`IDYES`) is **wrong for this dialog** — the Yes button is
1278, not 6. If the text match ever fails, the fallback fails too.

**`SSL VPN-Plus Client: User Authentication`** — note the full title contains a
colon; the code searches for the substring `User Authentication`, which matches:

| ID | Class | Control |
|---|---|---|
| 1221 | Static | `User Name` label |
| **1012** | Edit | Username field |
| 1220 | Static | `Password` label |
| **1219** | Edit | Password field (has `ES_PASSWORD` style) |
| **1218** | Button | `&Remember password` checkbox — **disabled and hidden** |
| 1 | Button | `OK` |
| **1109** | Button | `Cancel` |
| 1110 | Button | `Virtual Keyboard` |
| 1222 | Static | `Authentication required for SSL VPN-Plus gateway: ADA-VPN` |

`Fill-AuthForm` currently ignores these IDs and maps the two `Edit` controls
**by position**. Since the real IDs are now known, `GetDlgItem(hwnd, 1012)` and
`GetDlgItem(hwnd, 1219)` are available and remove the risk described under
"Known fragilities" below.

The password field can be identified independently of its ID by testing its
window style for `ES_PASSWORD` (`0x0020`) via `GetWindowLong(hwnd, GWL_STYLE)`.

**Settings dialog** (`SSL VPN-Plus Client - Settings`), reached from login button
1229. Controls live inside a `SysTabControl32` (12320) with a nested `#32770`
page, so a non-recursive child walk finds only the tab frame:

| ID | Control | State when observed |
|---|---|---|
| 1152 | Connection list | — |
| 1299 | Details list (hostname, IP, port) | — |
| 1058 | `Delete` | — |
| 1188 | `Details` | — |
| 1302 | `Validate Server's Security Certificate` checkbox | unchecked |
| 1303 | `Use local machine store for SSL client certificate authentication` checkbox | unchecked |
| 1304 | `Start client before Windows Logon for certificate authentication only` checkbox | hidden |
| 1305 | `Remember Username` checkbox | **checked** |
| 1 / 2 | `OK` / `Cancel` | — |

There is no `Remember password` option here.

### Standard dialog IDs

| ID | Meaning | Where |
|---|---|---|
| 1 | `IDOK` | `Fill-AuthForm` OK match, `Dismiss-SVPNotification` second probe |
| 2 | `IDOK` on info dialogs | `Dismiss-SVPNotification` first probe |
| 6 | `IDYES` | `Handle-SecurityAlert` fallback — **does not match this client's Security Alert**, which uses 1278 |

## Discovery technique

Both `Handle-SecurityAlert` and `Fill-AuthForm` log every child control they
find — class name, control ID, and text — before acting. If a client upgrade
changes the dialog layout, the activity log will contain the new IDs, which can
be read directly and folded back into the constants above.

To enumerate a dialog manually:

```powershell
$hwnd = [Win32]::FindWindowByTitle("User Authentication")
[Win32]::GetChildren($hwnd) | Format-Table ClassName, ControlId, Text, IsEnabled
```

## `SendMessage` blocks on modal dialogs

`SendMessage` is **synchronous**: it does not return until the target window's
message loop has finished processing the message. When the message opens a modal
dialog, the target's loop does not return to the caller until that dialog is
dismissed — so the `SendMessage` call blocks for as long as the dialog is open.

This was reproduced on 2026-09-05: `BM_CLICK` sent to the Settings button (1229)
did not return, and the calling process had to be abandoned after 120 seconds.
It only completed once the Settings dialog was closed by other means.

`AutoVPN.ps1` uses `SendMessage` for **every** click and text write. Any click
that causes SVPClient to raise a modal dialog will hang the calling thread — and
since that thread is also the UI thread, the whole application freezes, with no
timeout and no recovery path.

Two safe alternatives:

- **`PostMessage`** — queues the message and returns immediately. Correct for
  clicks where the result is observed by polling afterwards, which is exactly
  what the connect flow already does.
- **`SendMessageTimeout`** with `SMTO_ABORTIFHUNG` (`0x0002`) and an explicit
  timeout — behaves like `SendMessage` but gives up rather than hanging. Correct
  for `WM_GETTEXT`/`WM_GETTEXTLENGTH`, where a return value is needed.

```csharp
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
    uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
```

All four click sites have been migrated: the Login button
([AutoVPN.ps1:513](../AutoVPN.ps1)), the Security Alert Yes button
([AutoVPN.ps1:560](../AutoVPN.ps1)), the auth OK button
([AutoVPN.ps1:686](../AutoVPN.ps1)), and the notification dismiss
([AutoVPN.ps1:786](../AutoVPN.ps1)). They route through `Win32::ClickHandle`,
which posts rather than sends. `SendMessage` remains declared because the
timeout variants share its P/Invoke block, but no PowerShell code calls it.

## Known fragilities

- **Positional field mapping.** `Fill-AuthForm` assumes the first `Edit` control
  is the username and the second is the password. It does not check control IDs.
  A layout change that reorders or inserts an edit field would send the password
  into the wrong box — where it would be displayed in clear text, since only
  1219 carries the `ES_PASSWORD` style. The verified IDs above remove the need
  for this guess.
- **`SendMessage` has no timeout.** See the section above.
- **The `IDYES = 6` fallback is wrong** for this client's Security Alert, which
  uses 1278.
- **Title matching is substring-based and case-insensitive.** Any other
  application with a matching title could be found first, since `EnumWindows`
  returns in z-order and the search stops at the first hit.
- **No process filtering in practice.** `FindWindowByPidAndTitle` exists but the
  automation engine only ever calls `FindWindowByTitle`, so nothing constrains a
  match to the SVPClient process.

## Certificate warnings observed

The `Security Alert` dialog for gateway `ADA-VPN` reports three distinct
problems simultaneously:

- the certificate was issued by an authority the machine does not trust
- the certificate has expired or is not yet valid
- the name on the certificate does not match the server

`Handle-SecurityAlert` clicks `Yes` unconditionally, which is equivalent to what
a user does by hand, but it means the automation accepts a certificate that
fails validation on all three counts. The `Validate Server's Security
Certificate` option in the client's Settings (id 1302) is also unchecked.

This is recorded as an observation, not a defect in this project — changing it
would require the gateway's certificate to be fixed.
