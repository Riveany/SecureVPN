# ============================================================================
# AutoVPN v2.0 - VMware SSL VPN-Plus Auto-Connect
# ============================================================================
# GUI application for one-click VPN connection with saved credentials.
# Uses Win32 Messages (GetDlgItem + SendMessage) instead of SendKeys
# for reliable, focus-independent automation.
# ============================================================================

# -Background starts straight to the tray with no window shown. The logon task
# created by Set-AutoStart passes it: -WindowStyle Hidden only suppresses the
# PowerShell console, not this application's own form, so without this the app
# would still pop a window in the user's face at every logon.
#
# Works in both a .ps1 run and a PS2EXE-compiled build. The hiding is done with
# ShowWindow(SW_HIDE) from a short timer rather than Form.Hide() in Add_Shown,
# because the latter leaves the window visible in a compiled build.
param(
    [switch]$Background
)

#region [1] Assembly & Type Loading
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public class Win32 {
    // Window finding
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern IntPtr GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    // Dialog controls
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);

    // Messages
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    // SendMessage blocks until the target's message loop finishes handling the
    // message. If the click opens a modal dialog, that never happens until the
    // dialog closes - which hangs this thread with no timeout. Use the timeout
    // variants for anything that needs a return value, PostMessage for clicks.
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, StringBuilder lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    // Window state
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    // ShowWindow is currently unused: the automation deliberately does not
    // restore or raise SVPClient's windows, since BM_CLICK does not need it.
    // Kept declared because it is the obvious tool if a future dialog ever does.
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    // Message constants
    public const uint WM_SETTEXT    = 0x000C;
    public const uint WM_GETTEXT    = 0x000D;
    public const uint WM_GETTEXTLENGTH = 0x000E;
    public const uint BM_CLICK      = 0x00F5;
    public const uint WM_COMMAND    = 0x0111;
    public const uint WM_CLOSE      = 0x0010;
    public const uint BN_CLICKED    = 0;
    public const int  SW_HIDE       = 0;
    public const int  SW_SHOW       = 5;
    public const int  SW_RESTORE    = 9;

    // SendMessageTimeout flags / defaults
    public const uint SMTO_ABORTIFHUNG = 0x0002;
    public const uint MSG_TIMEOUT_MS   = 3000;

    // GetWindowLong index and Edit style bit used to identify a password field
    public const int  GWL_STYLE     = -16;
    public const int  ES_PASSWORD   = 0x0020;

    // SVPClient known dialog control IDs (Login window)
    public const int ID_LOGIN_BTN    = 1018;
    public const int ID_CLOSE_BTN    = 1109;
    public const int ID_SETTINGS_BTN = 1229;
    public const int ID_DETAILS_BTN  = 1058;
    public const int ID_NETWORK_COMBO = 1047;
    public const int ID_PROGRESS_BAR = 1226;

    // Systray Dialog control IDs (when connected)
    public const int ID_SYSTRAY_CANCEL_BTN = 1016;  // &Cancel = disconnect
    public const int ID_SYSTRAY_LOGIN_BTN  = 1018;  // &Login (disabled when connected)

    // Security Alert dialog - verified by live enumeration against v6.3.0.
    // Note this dialog does NOT use the standard IDYES = 6.
    public const int ID_SECALERT_YES  = 1278;
    public const int ID_SECALERT_NO   = 1279;
    public const int ID_SECALERT_VIEW = 1079;

    // "SSL VPN-Plus Client: User Authentication" dialog - verified by live
    // enumeration. Previously these controls were located by position, which
    // risked typing the password into the visible username box if the layout
    // ever changed.
    public const int ID_AUTH_USER   = 1012;
    public const int ID_AUTH_PASS   = 1219;
    public const int ID_AUTH_OK     = 1;
    public const int ID_AUTH_CANCEL = 1109;
    public const int ID_AUTH_REMEMBER_PASS = 1218;  // disabled + hidden by gateway policy

    /// <summary>Find a visible window by exact or partial title match</summary>
    public static IntPtr FindWindowByTitle(string titlePart) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            StringBuilder sb = new StringBuilder(512);
            GetWindowText(hWnd, sb, 512);
            if (sb.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    /// <summary>Find ANY window (visible or hidden) by partial title for a specific process</summary>
    public static IntPtr FindWindowByPidAndTitle(uint pid, string titlePart) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            uint wndPid;
            GetWindowThreadProcessId(hWnd, out wndPid);
            if (wndPid != pid) return true;
            StringBuilder sb = new StringBuilder(512);
            GetWindowText(hWnd, sb, 512);
            if (sb.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    /// <summary>Enumerate all child controls of a dialog</summary>
    public static List<ChildInfo> GetChildren(IntPtr parent) {
        var list = new List<ChildInfo>();
        IntPtr child = IntPtr.Zero;
        while (true) {
            child = FindWindowEx(parent, child, null, null);
            if (child == IntPtr.Zero) break;

            StringBuilder txt = new StringBuilder(256);
            StringBuilder cls = new StringBuilder(256);
            GetWindowText(child, txt, 256);
            GetClassName(child, cls, 256);
            int id = GetDlgCtrlID(child);
            bool enabled = IsWindowEnabled(child);

            list.Add(new ChildInfo { Handle = child, Text = txt.ToString(), ClassName = cls.ToString(), ControlId = id, IsEnabled = enabled });
        }
        return list;
    }

    /// <summary>Click a control handle without blocking on a modal dialog</summary>
    public static void ClickHandle(IntPtr btn) {
        // PostMessage, not SendMessage: if this click opens a modal dialog the
        // synchronous form would not return until that dialog is dismissed.
        PostMessage(btn, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
    }

    /// <summary>Click a button by control ID. Returns false if not found.</summary>
    public static bool ClickButton(IntPtr parent, int controlId) {
        IntPtr btn = GetDlgItem(parent, controlId);
        if (btn == IntPtr.Zero) return false;
        ClickHandle(btn);
        return true;
    }

    /// <summary>Set text on a control handle. Bounded by a timeout.</summary>
    public static bool SetTextHandle(IntPtr ctrl, string text) {
        if (ctrl == IntPtr.Zero) return false;
        IntPtr result;
        IntPtr ok = SendMessageTimeout(ctrl, WM_SETTEXT, IntPtr.Zero, text,
                                       SMTO_ABORTIFHUNG, MSG_TIMEOUT_MS, out result);
        return ok != IntPtr.Zero;
    }

    /// <summary>Set text on a control via WM_SETTEXT</summary>
    public static bool SetText(IntPtr parent, int controlId, string text) {
        return SetTextHandle(GetDlgItem(parent, controlId), text);
    }

    /// <summary>Get text from a control via WM_GETTEXT. Bounded by a timeout.</summary>
    public static string GetText(IntPtr hwnd) {
        IntPtr result;
        if (SendMessageTimeout(hwnd, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero,
                               SMTO_ABORTIFHUNG, MSG_TIMEOUT_MS, out result) == IntPtr.Zero) {
            return "";  // target hung or timed out
        }
        int len = (int)result;
        if (len <= 0) return "";
        StringBuilder sb = new StringBuilder(len + 1);
        // NOTE: the buffer must be passed as StringBuilder, not sb.ToString(),
        // or the receiving text is written into a throwaway copy.
        if (SendMessageTimeout(hwnd, WM_GETTEXT, (IntPtr)(len + 1), sb,
                               SMTO_ABORTIFHUNG, MSG_TIMEOUT_MS, out result) == IntPtr.Zero) {
            return "";
        }
        return sb.ToString();
    }

    /// <summary>True if this Edit control has the ES_PASSWORD style</summary>
    public static bool IsPasswordField(IntPtr hwnd) {
        return (GetWindowLong(hwnd, GWL_STYLE) & ES_PASSWORD) != 0;
    }
}

public class ChildInfo {
    public IntPtr Handle;
    public string Text;
    public string ClassName;
    public int ControlId;
    public bool IsEnabled;
}
"@
#endregion

#region [2] Global Variables
# Detect script directory (works for both .ps1 and PS2EXE .exe)
if ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName -match '\.exe$' -and
    -not ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName -match 'powershell\.exe$|pwsh\.exe$')) {
    # Running as compiled .exe
    $Script:ScriptDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
} else {
    # Running as .ps1 script
    $Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$Script:ConfigPath  = Join-Path $Script:ScriptDir "config.json"
$Script:Config      = $null
$Script:MainForm    = $null
$Script:LogBox      = $null
$Script:StatusLabel = $null
$Script:StatusIcon  = $null
$Script:ConnectBtn  = $null
$Script:DisconnectBtn = $null
$Script:TrayIcon    = $null

# Controls that are NOT part of the form's Controls collection, or that
# Update-UIState would otherwise be unable to reach. ContextMenuStrip items
# carry their own Enabled property, so disabling the form's buttons does nothing
# for them. See docs/04-background-service.md.
$Script:SettingsBtn    = $null
$Script:TrayConnect    = $null
$Script:TrayDisconnect = $null
$Script:TraySettings   = $null


# --- Background worker -----------------------------------------------------
# The automation engine runs on its own thread, so the UI thread is never blocked
# and never has to pump the message loop mid-sequence. Windows Forms controls may
# only be touched from the thread that created them, so everything the worker
# wants to show goes through Invoke-OnUI, which marshals via Control.Invoke.
$Script:Worker         = $null   # PowerShell instance doing the work
$Script:WorkerHandle   = $null   # its IAsyncResult
$Script:WorkerRunspace = $null
$Script:WorkerPoll     = $null   # UI-thread timer that reaps the worker

# A separate runspace does NOT share $Script: variables - verified, not assumed.
# Flags that both threads must see live in this synchronized hashtable instead,
# which is handed to the worker runspace as $SharedState. The $Script:* flags
# above remain the UI thread's view and are kept in step with it.
$Script:Shared = [hashtable]::Synchronized(@{
    Cancel               = $false
    DisconnectAfterCancel = $false
    IsConnecting         = $false
    IsDisconnecting      = $false
})

# Set when a disconnect was requested during a connect. Connect-VPN's finally
# block performs the disconnect once its own stack has unwound, which avoids
# the deadlock of waiting for it from inside its own message pump.
$Script:Shared.DisconnectAfterCancel = $false
#endregion

#region [3] Config Management
function Load-Config {
    if (Test-Path $Script:ConfigPath) {
        try {
            $Script:Config = Get-Content $Script:ConfigPath -Raw | ConvertFrom-Json
            return $true
        } catch {
            $Script:Config = $null
        }
    }
    # Create default config
    $Script:Config = [PSCustomObject]@{
        vpn_client_path = "C:\Program Files (x86)\VMware\SSL VPN-Plus Client\SVPClient.exe"
        connection_name = "ADA-VPN"
        auto_connect    = $false
        minimize_to_tray = $true
        credential_file = "vpn_cred.dat"
        version         = "2.0"
    }
    Save-Config
    return $true
}

function Save-Config {
    $Script:Config | ConvertTo-Json -Depth 5 | Set-Content $Script:ConfigPath -Encoding UTF8
}

function Get-CredFilePath {
    $credFile = $Script:Config.credential_file
    if ([System.IO.Path]::IsPathRooted($credFile)) { return $credFile }
    return Join-Path $Script:ScriptDir $credFile
}
#endregion

#region [4] Credential Management (DPAPI)
function Save-VpnCredential {
    param([string]$Username, [string]$Password)

    $secUser = ConvertTo-SecureString $Username -AsPlainText -Force
    $secPass = ConvertTo-SecureString $Password -AsPlainText -Force

    $data = @{
        u = $secUser | ConvertFrom-SecureString
        p = $secPass | ConvertFrom-SecureString
    }

    $data | ConvertTo-Json | Set-Content (Get-CredFilePath) -Encoding UTF8
    Write-Log "Credentials saved successfully." "Green"
}

function Load-VpnCredential {
    $credPath = Get-CredFilePath
    if (-not (Test-Path $credPath)) { return $null }

    try {
        $data = Get-Content $credPath -Raw | ConvertFrom-Json
        $secUser = $data.u | ConvertTo-SecureString
        $secPass = $data.p | ConvertTo-SecureString

        $credUser = New-Object System.Management.Automation.PSCredential("x", $secUser)
        $credPass = New-Object System.Management.Automation.PSCredential("x", $secPass)

        return @{
            Username = $credUser.GetNetworkCredential().Password
            Password = $credPass.GetNetworkCredential().Password
        }
    } catch {
        Write-Log "Failed to load credentials: $_" "Red"
        return $null
    }
}

function Test-VpnCredential {
    return (Test-Path (Get-CredFilePath))
}

function Reset-VpnCredential {
    $credPath = Get-CredFilePath
    if (Test-Path $credPath) {
        Remove-Item $credPath -Force
        Write-Log "Credentials deleted." "Yellow"
    }
}
#endregion

#region [5] Logging
<#
.SYNOPSIS
    Run a script block on the UI thread.
.DESCRIPTION
    Windows Forms controls may only be touched from the thread that created
    them. The automation engine runs on a worker thread, so every control access
    it makes has to be marshalled. Control.Invoke does that, and blocks until
    the UI thread has run the block - which is what we want, since the caller
    usually wants the UI to reflect reality before it moves on.

    Falls through to a direct call when there is no form yet (startup, or the
    headless test harness), or when we are already on the UI thread.
#>
function Invoke-OnUI {
    param([scriptblock]$Action)

    $form = $Script:MainForm
    if (-not $form -or $form.IsDisposed -or -not $form.IsHandleCreated) {
        try { & $Action } catch { }
        return
    }

    try {
        if ($form.InvokeRequired) {
            $form.Invoke([Action]$Action) | Out-Null
        } else {
            & $Action
        }
    } catch {
        # Form torn down between the check and the call - nothing to update.
    }
}

function Write-Log {
    param([string]$Message, [string]$Color = "White")

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message"

    # Capture the control into a local BEFORE building the closure. $Script:
    # inside a marshalled block resolves against the UI thread's scope, where
    # the worker's variables do not exist; a local is carried by the closure.
    $box = $Script:LogBox
    if ($box) {
        Invoke-OnUI {
            if (-not $box.IsDisposed) {
                try {
                    $box.AppendText("$line`r`n")
                    $box.SelectionStart = $box.TextLength
                    $box.ScrollToCaret()
                } catch {
                    # Form not ready yet - ignore
                }
            }
        }.GetNewClosure()
    }

    # NOT Write-Host: PS2EXE builds with -NoConsole turn Write-Host into a
    # MessageBox, so every log line would pop a dialog - which is exactly what
    # made -Background look broken in the compiled build. The WinForms window was
    # hidden correctly all along; the visible '#32770' was this MessageBox.
    # [Console]::WriteLine writes to a real console when there is one and is a
    # harmless no-op when there is not.
    try { [Console]::WriteLine($line) } catch { }
}
#endregion

#region [6] VPN Automation Engine
function Start-SVPClient {
    $vpnPath = $Script:Config.vpn_client_path
    if (-not (Test-Path $vpnPath)) {
        Write-Log "ERROR: SVPClient not found at: $vpnPath" "Red"
        return $false
    }

    $proc = Get-Process -Name "SVPClient" -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Log "SVPClient already running (PID: $($proc.Id))" "Green"
        return $true
    }

    Write-Log "Starting SVPClient..." "Yellow"
    Start-Process -FilePath $vpnPath
    Start-Sleep -Seconds 3

    $proc = Get-Process -Name "SVPClient" -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Log "SVPClient started (PID: $($proc.Id))" "Green"
        return $true
    }

    Write-Log "ERROR: Failed to start SVPClient" "Red"
    return $false
}

function Find-SVPLoginWindow {
    param([int]$TimeoutSeconds = 30)

    # Returns hashtable: @{ Status = "found"|"connected"|"timeout"; Handle = [IntPtr] }

    # Quick check: already connected via adapter?
    if (Test-VpnConnectedNow) {
        Write-Log "VPN is already connected! (adapter check)" "Green"
        return @{ Status = "connected"; Handle = [IntPtr]::Zero }
    }

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-Cancelled) { return @{ Status = "cancelled"; Handle = [IntPtr]::Zero } }

        $hwnd = [Win32]::FindWindowByTitle("SSL VPN-Plus Client - Login")
        if ($hwnd -ne [IntPtr]::Zero) {
            Write-Log "Found Login window (HWND: $($hwnd.ToInt64()))" "Green"
            return @{ Status = "found"; Handle = $hwnd }
        }

        # Check if connected while waiting
        if (Test-VpnConnectedNow) {
            Write-Log "VPN is already connected! (adapter check)" "Green"
            return @{ Status = "connected"; Handle = [IntPtr]::Zero }
        }

        DoEvents-Sleep 500
        $elapsed++
    }

    Write-Log "ERROR: Login window not found within ${TimeoutSeconds}s" "Red"
    return @{ Status = "timeout"; Handle = [IntPtr]::Zero }
}

function Click-LoginButton {
    param([IntPtr]$LoginWindowHwnd)

    Write-Log "Clicking Login button..." "Yellow"

    # No ShowWindow/SW_RESTORE here on purpose. BM_CLICK is delivered to the
    # control's message queue and does not require the window to be visible,
    # restored, or focused - verified by clicking Login on a deliberately
    # minimized window and watching the Security Alert appear, with the
    # foreground window unchanged. Restoring it only yanked the client in front
    # of whatever the user was doing, and gave them a window to click on
    # mid-sequence. See docs/04-background-service.md.
    $result = [Win32]::ClickButton($LoginWindowHwnd, [Win32]::ID_LOGIN_BTN)
    if ($result) {
        Write-Log "Login button clicked" "Green"
    } else {
        Write-Log "ERROR: Could not find Login button (ID: $([Win32]::ID_LOGIN_BTN))" "Red"
    }
    return $result
}

function Handle-SecurityAlert {
    param([int]$TimeoutSeconds = 10)

    # The Security Alert dialog has title "Security Alert" with Yes/No/View Certificate buttons
    # We need to click "Yes" to proceed
    Write-Log "Checking for Security Alert dialog..." "Yellow"
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-Cancelled) { return $false }

        $hwnd = [Win32]::FindWindowByTitle("Security Alert")
        if ($hwnd -ne [IntPtr]::Zero) {
            Write-Log "Found Security Alert dialog (HWND: $($hwnd.ToInt64()))" "Yellow"

            # Preferred: the verified control ID for this client's Yes button.
            # This dialog does NOT use the standard IDYES = 6.
            if ([Win32]::ClickButton($hwnd, [Win32]::ID_SECALERT_YES)) {
                Write-Log "Clicked Yes (ID: $([Win32]::ID_SECALERT_YES)) on Security Alert" "Green"
                Write-Log "Security Alert accepted" "Green"
                return $true
            }

            # Fallback: locate the Yes button by text
            $children = [Win32]::GetChildren($hwnd)
            $yesBtn = $null
            foreach ($child in $children) {
                if ($child.ClassName -eq "Button" -and $child.Text -eq "&Yes") {
                    $yesBtn = $child
                    break
                }
                if ($child.ClassName -eq "Button" -and $child.Text -eq "Yes") {
                    $yesBtn = $child
                    break
                }
            }

            if ($yesBtn) {
                Write-Log "Clicking Yes on Security Alert..." "Yellow"
                [Win32]::ClickHandle($yesBtn.Handle)
                Write-Log "Security Alert accepted" "Green"
                return $true
            } else {
                # Try standard IDYES = 6 via GetDlgItem
                $yesBtnHwnd = [Win32]::GetDlgItem($hwnd, 6)
                if ($yesBtnHwnd -ne [IntPtr]::Zero) {
                    Write-Log "Clicking Yes (ID=6) on Security Alert..." "Yellow"
                    [Win32]::ClickHandle($yesBtnHwnd)
                    Write-Log "Security Alert accepted" "Green"
                    return $true
                }
                Write-Log "WARNING: Yes button not found in Security Alert" "Yellow"
                # Log all buttons for debugging
                foreach ($child in $children) {
                    if ($child.ClassName -eq "Button") {
                        Write-Log "  Button: ID=$($child.ControlId) Text='$($child.Text)'" "Cyan"
                    }
                }
            }
            return $false
        }
        DoEvents-Sleep 500
        $elapsed++
    }

    # No Security Alert appeared - that's fine, not always shown
    Write-Log "No Security Alert dialog (OK)" "Green"
    return $true
}

function Find-AuthWindow {
    param([int]$TimeoutSeconds = 30)

    Write-Log "Waiting for Authentication window..." "Yellow"
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-Cancelled) { return [IntPtr]::Zero }

        # Also handle Security Alert if it pops up during wait
        $secHwnd = [Win32]::FindWindowByTitle("Security Alert")
        if ($secHwnd -ne [IntPtr]::Zero) {
            Handle-SecurityAlert -TimeoutSeconds 5 | Out-Null
            DoEvents-Sleep 1000
            continue
        }

        $hwnd = [Win32]::FindWindowByTitle("User Authentication")
        if ($hwnd -ne [IntPtr]::Zero) {
            Write-Log "Found Authentication window (HWND: $($hwnd.ToInt64()))" "Green"
            return $hwnd
        }

        # Check if VPN connected without needing auth (e.g., remembered credentials)
        if ($elapsed -gt 10 -and (Test-VpnConnectedNow)) {
            Write-Log "VPN connected (no auth needed)" "Green"
            return [IntPtr](-1)  # Special value: connected without auth
        }

        DoEvents-Sleep 500
        $elapsed++
    }

    Write-Log "ERROR: Authentication window not found within ${TimeoutSeconds}s" "Red"
    return [IntPtr]::Zero
}

function Fill-AuthForm {
    param([IntPtr]$AuthWindowHwnd, [string]$Username, [string]$Password)

    Write-Log "Analyzing Authentication dialog controls..." "Yellow"

    # Enumerate all children to find Edit controls
    $children = [Win32]::GetChildren($AuthWindowHwnd)

    $editControls = @()
    $buttonControls = @()

    foreach ($child in $children) {
        if ($child.ClassName -eq "Edit") {
            $editControls += $child
            Write-Log "  Found Edit control: ID=$($child.ControlId) Text='$($child.Text)'" "Cyan"
        }
        if ($child.ClassName -eq "Button") {
            $buttonControls += $child
            Write-Log "  Found Button: ID=$($child.ControlId) Text='$($child.Text)'" "Cyan"
        }
    }

    # Resolve the two fields. Preferred: verified control IDs. Fallback: the old
    # positional guess, but only after confirming the ES_PASSWORD style is where
    # it is expected - otherwise the password would be typed into a visible box.
    $userHwnd = [Win32]::GetDlgItem($AuthWindowHwnd, [Win32]::ID_AUTH_USER)
    $passHwnd = [Win32]::GetDlgItem($AuthWindowHwnd, [Win32]::ID_AUTH_PASS)

    if ($userHwnd -ne [IntPtr]::Zero -and $passHwnd -ne [IntPtr]::Zero -and [Win32]::IsPasswordField($passHwnd)) {
        Write-Log "Using verified control IDs (user=$([Win32]::ID_AUTH_USER), pass=$([Win32]::ID_AUTH_PASS))" "Cyan"
    } else {
        Write-Log "Verified control IDs not found - falling back to positional mapping" "Yellow"

        if ($editControls.Count -lt 2) {
            Write-Log "ERROR: Expected 2 Edit controls (user/pass), found $($editControls.Count)" "Red"
            return $false
        }

        $userHwnd = $editControls[0].Handle
        $passHwnd = $editControls[1].Handle

        # Refuse to type the password into a field that does not mask input.
        if (-not [Win32]::IsPasswordField($passHwnd)) {
            Write-Log "ERROR: Second Edit control is not a password field - aborting to avoid exposing the password" "Red"
            return $false
        }
    }

    Write-Log "Setting username..." "Yellow"
    [Win32]::SetTextHandle($userHwnd, $Username) | Out-Null
    Start-Sleep -Milliseconds 200

    Write-Log "Setting password..." "Yellow"
    [Win32]::SetTextHandle($passHwnd, $Password) | Out-Null
    Start-Sleep -Milliseconds 200

    # Find OK button - prefer the verified control ID
    $okHwnd = [Win32]::GetDlgItem($AuthWindowHwnd, [Win32]::ID_AUTH_OK)
    if ($okHwnd -ne [IntPtr]::Zero) {
        Write-Log "Clicking OK button (ID: $([Win32]::ID_AUTH_OK))..." "Yellow"
        [Win32]::ClickHandle($okHwnd)
        Write-Log "Authentication submitted!" "Green"
        return $true
    }

    $okBtn = $buttonControls | Where-Object { $_.Text -match "OK|Login|Submit|Connect" -or $_.ControlId -eq 1 } | Select-Object -First 1
    if (-not $okBtn) {
        # Fallback: first enabled button
        $okBtn = $buttonControls | Where-Object { $_.IsEnabled } | Select-Object -First 1
    }

    if ($okBtn) {
        Write-Log "Clicking OK button (ID: $($okBtn.ControlId), Text: '$($okBtn.Text)')..." "Yellow"
        [Win32]::ClickHandle($okBtn.Handle)
        Write-Log "Authentication submitted!" "Green"
        return $true
    }

    Write-Log "ERROR: OK button not found" "Red"
    return $false
}

function Test-VpnConnectedNow {
    # Quick check: Is VMware SSL VPN-Plus Client Adapter "Up"?
    try {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceDescription -like "*VMware SSL VPN*" -or
            $_.InterfaceDescription -like "*SSL VPN-Plus*"
        }
        if ($adapter -and $adapter.Status -eq "Up") {
            return $true
        }
    } catch {
        # Fallback: check if SVPClient is running with no Login window visible
    }

    # Fallback: SVPClient running + no Login window = likely connected
    $proc = Get-Process -Name "SVPClient" -ErrorAction SilentlyContinue
    if ($proc) {
        $loginHwnd = [Win32]::FindWindowByTitle("SSL VPN-Plus Client - Login")
        if ($loginHwnd -eq [IntPtr]::Zero) {
            # No login window visible, process running = connected
            return $true
        }
    }

    return $false
}

function Test-VpnConnected {
    param([int]$TimeoutSeconds = 30)

    Write-Log "Verifying VPN connection..." "Yellow"
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-Cancelled) { return $false }

        if (Test-VpnConnectedNow) {
            Write-Log "VPN Connected! (adapter verified)" "Green"
            return $true
        }

        # Check if Login window came back (auth failed)
        $hwndLogin = [Win32]::FindWindowByTitle("SSL VPN-Plus Client - Login")
        if ($hwndLogin -ne [IntPtr]::Zero -and $elapsed -gt 10) {
            Write-Log "WARNING: Login screen reappeared - connection may have failed" "Yellow"
            return $false
        }

        DoEvents-Sleep 1000
        $elapsed++
    }

    # Final check
    if (Test-VpnConnectedNow) {
        Write-Log "VPN Connected! (adapter verified)" "Green"
        return $true
    }

    Write-Log "Connection verification timed out" "Yellow"
    return $false
}

function Dismiss-SVPNotification {
    # Auto-dismiss "SSL VPN connection established with network ADA-VPN" popup
    # This is a small #32770 dialog from SVPClient with title "SSL VPN-Plus Client" and OK button
    $maxAttempts = 5
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        if ($Script:Shared.Cancel) { return }

        $hwnd = [Win32]::FindWindowByTitle("SSL VPN-Plus Client")
        if ($hwnd -ne [IntPtr]::Zero) {
            # Check if this is the notification dialog (has OK button with ID=1 or ID=2)
            $okBtn = [Win32]::GetDlgItem($hwnd, 2)  # IDOK = 2 for info dialogs
            if ($okBtn -eq [IntPtr]::Zero) {
                $okBtn = [Win32]::GetDlgItem($hwnd, 1)  # IDOK = 1
            }
            if ($okBtn -ne [IntPtr]::Zero) {
                Write-Log "Dismissing SVPClient notification..." "Yellow"
                [Win32]::ClickHandle($okBtn)
                Write-Log "Notification dismissed" "Green"
                return
            }
        }
        DoEvents-Sleep 1000
    }
}

<#
.SYNOPSIS
    Sleep that gives up early when a cancel arrives.
.DESCRIPTION
    Named for what it used to be. It no longer pumps the message loop: the
    automation runs on a worker thread, where DoEvents would pump nothing and
    Application::DoEvents is not the worker's to call. The UI thread stays
    responsive on its own because it is not blocked in the first place.
#>
function DoEvents-Sleep {
    param([int]$Milliseconds)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
        if ($Script:Shared.Cancel) { return }
        Start-Sleep -Milliseconds 100
    }
}

<#
.SYNOPSIS
    True if the user has asked to cancel the running connect sequence.
.DESCRIPTION
    Called at the top of every polling loop in the automation engine. Logs once
    per check so the activity log shows where the sequence stopped.
#>
function Test-Cancelled {
    if ($Script:Shared.Cancel) {
        Write-Log "Cancel requested - stopping connect sequence" "Yellow"
        return $true
    }
    return $false
}

<#
.SYNOPSIS
    Enable or disable every control that can start or stop VPN work.
.DESCRIPTION
    The form's Connect and Disconnect buttons are handled by Update-UIState.
    The tray menu items and the Settings button are not part of that path -
    ContextMenuStrip items carry their own Enabled property - so they are set
    here. AllowDisconnect stays true during a connect so the user can cancel.
#>
function Set-ActionsEnabled {
    param(
        [bool]$Enabled,
        [bool]$AllowDisconnect = $false
    )

    $sb = $Script:SettingsBtn; $ts = $Script:TraySettings
    $tc = $Script:TrayConnect;  $td = $Script:TrayDisconnect
    $canDisconnect = ($Enabled -or $AllowDisconnect)

    Invoke-OnUI {
        try {
            if ($sb) { $sb.Enabled = $Enabled }
            if ($ts) { $ts.Enabled = $Enabled }
            if ($tc) { $tc.Enabled = $Enabled }
            if ($td) { $td.Enabled = $canDisconnect }
        } catch {
            # Controls not built yet - ignore
        }
    }.GetNewClosure()
}

<#
.SYNOPSIS
    Show a tray balloon from either thread.
#>
function Show-Balloon {
    param([string]$Text, [string]$Icon = "Info")

    $tray = $Script:TrayIcon
    if (-not $tray) { return }

    Invoke-OnUI {
        try {
            $tray.BalloonTipTitle = "AutoVPN"
            $tray.BalloonTipText  = $Text
            $tray.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::$Icon
            $tray.ShowBalloonTip(3000)
        } catch { }
    }.GetNewClosure()
}

function Connect-VPNCore {
    if ($Script:Shared.IsConnecting) {
        Write-Log "Connection already in progress..." "Yellow"
        return
    }
    if ($Script:Shared.IsDisconnecting) {
        Write-Log "Disconnect in progress - please wait" "Yellow"
        return
    }

    $Script:Shared.IsConnecting = $true
    $Script:Shared.Cancel = $false
    Update-UIState "Connecting"
    # Leave Disconnect reachable so the user can cancel; block everything else.
    Set-ActionsEnabled -Enabled $false -AllowDisconnect $true

    try {
        # Load credentials
        $cred = Load-VpnCredential
        if (-not $cred) {
            Write-Log "No credentials found. Please configure in Settings." "Red"
            Update-UIState "Disconnected"
            return
        }

        # Step 1: Start SVPClient
        Write-Log "Step 1: Starting SVPClient..." "Yellow"
        if (-not (Start-SVPClient)) {
            Update-UIState "Error"
            return
        }

        DoEvents-Sleep 2000

        # Step 2: Find Login window
        Write-Log "Step 2: Finding Login window..." "Yellow"
        $loginResult = Find-SVPLoginWindow -TimeoutSeconds 15
        if ($loginResult.Status -eq "connected") {
            Update-UIState "Connected"
            return
        }
        if ($loginResult.Status -eq "cancelled") { return }
        if ($loginResult.Status -eq "timeout") {
            Update-UIState "Error"
            return
        }
        $loginHwnd = $loginResult.Handle

        if (Test-Cancelled) { return }

        # Step 3: Click Login button
        Write-Log "Step 3: Clicking Login..." "Yellow"
        if (-not (Click-LoginButton -LoginWindowHwnd $loginHwnd)) {
            Update-UIState "Error"
            return
        }

        DoEvents-Sleep 2000

        # Step 4: Handle Security Alert (certificate dialog)
        Write-Log "Step 4: Checking for Security Alert..." "Yellow"
        Handle-SecurityAlert -TimeoutSeconds 10 | Out-Null

        DoEvents-Sleep 1000

        if (Test-Cancelled) { return }

        # Step 5: Find Auth window
        Write-Log "Step 5: Waiting for Authentication..." "Yellow"
        $authHwnd = Find-AuthWindow -TimeoutSeconds 20

        if ($Script:Shared.Cancel) { return }

        if ($authHwnd -eq [IntPtr]::Zero) {
            # Check if VPN connected anyway
            if (Test-VpnConnectedNow) {
                Write-Log "VPN connected (no auth needed)" "Green"
                Update-UIState "Connected"
                return
            }
            Update-UIState "Error"
            return
        }

        if ($authHwnd.ToInt64() -eq -1) {
            # Special: connected without needing auth
            Update-UIState "Connected"
            Show-Balloon "VPN Connected" "Info"
            return
        }

        if (Test-Cancelled) { return }

        # Step 6: Fill auth form
        Write-Log "Step 6: Filling credentials..." "Yellow"
        $username = $cred.Username
        $password = $cred.Password
        $result = Fill-AuthForm -AuthWindowHwnd $authHwnd -Username $username -Password $password

        # Clear password from memory
        $password = $null
        $cred = $null
        [System.GC]::Collect()

        if (-not $result) {
            Update-UIState "Error"
            return
        }

        # Step 7: Verify connection
        Write-Log "Step 7: Verifying connection..." "Yellow"
        DoEvents-Sleep 3000
        if (Test-VpnConnected -TimeoutSeconds 30) {
            Update-UIState "Connected"

            # Auto-dismiss "connection established" notification from SVPClient
            Dismiss-SVPNotification

            Show-Balloon "VPN Connected" "Info"
        } else {
            # Still try to dismiss notification even if verification times out
            Dismiss-SVPNotification
            Update-UIState "Disconnected"
            Write-Log "Connection may have failed - check SVPClient" "Yellow"
        }
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)" "Red"
        Update-UIState "Error"
    } finally {
        $Script:Shared.IsConnecting = $false

        if ($Script:Shared.Cancel) {
            # The sequence was abandoned partway through. Report the real
            # adapter state rather than assuming either outcome.
            Write-Log "Connect sequence cancelled" "Yellow"
            if (Test-VpnConnectedNow) { Update-UIState "Connected" }
            else                      { Update-UIState "Disconnected" }
        }

        Set-ActionsEnabled -Enabled $true

        # A disconnect requested mid-connect is NOT run here. This is the worker
        # thread; the UI-thread reaper in Start-VpnWorker starts a fresh worker
        # for it once this one has been disposed.
    }
}

function Disconnect-VPNCore {
    if ($Script:Shared.IsDisconnecting) {
        Write-Log "Disconnect already in progress..." "Yellow"
        return
    }

    # Connect-VPNCore's finally block is the only caller that may invoke this
    # while IsConnecting is still set - it does so as it unwinds, having already
    # cleared the flag. Any other overlap is a bug in the dispatcher.

    $Script:Shared.IsDisconnecting = $true
    Set-ActionsEnabled -Enabled $false

    try {
    Write-Log "Disconnecting VPN..." "Yellow"
    Update-UIState "Disconnecting"

    if (-not (Test-VpnConnectedNow)) {
        Write-Log "VPN already disconnected" "Yellow"
        Update-UIState "Disconnected"
        return
    }

    # SVPClient requires elevated privileges to kill (protected by NeoSrv service)
    # Must use RunAs to get admin rights - will trigger UAC prompt
    Write-Log "Stopping SVPClient (requires Admin)..." "Yellow"

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c taskkill /F /IM SVPClient.exe"
        $psi.Verb = "runas"
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $elevatedProc = [System.Diagnostics.Process]::Start($psi)
        Write-Log "UAC accepted, killing SVPClient..." "Yellow"
        $elevatedProc.WaitForExit(10000)
        Write-Log "Kill command completed" "Green"
    } catch {
        # User cancelled UAC or other error
        Write-Log "Could not stop SVPClient: $($_.Exception.Message)" "Red"
        Update-UIState "Connected"
        return
    }

    # Wait for adapter to go down
    Write-Log "Waiting for VPN to disconnect..." "Yellow"
    $maxWait = 15
    $waited = 0
    while ($waited -lt $maxWait) {
        DoEvents-Sleep 1000
        $waited++

        $adapterUp = $false
        try {
            $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
                $_.InterfaceDescription -like "*VMware SSL VPN*" -or
                $_.InterfaceDescription -like "*SSL VPN-Plus*"
            }
            if ($adapter -and $adapter.Status -eq "Up") {
                $adapterUp = $true
            }
        } catch {}

        if (-not $adapterUp) {
            Write-Log "VPN Disconnected!" "Green"
            Update-UIState "Disconnected"
            Show-Balloon "VPN Disconnected" "Warning"
            return
        }
        Write-Log "  Waiting... ($waited/$maxWait)" "Yellow"
    }

    # Final check
    if (Test-VpnConnectedNow) {
        Write-Log "VPN still connected - disconnect failed" "Red"
        Update-UIState "Connected"
    } else {
        Write-Log "VPN Disconnected!" "Green"
        Update-UIState "Disconnected"
    }

    } finally {
        $Script:Shared.IsDisconnecting = $false
        $Script:Shared.Cancel = $false
        $Script:Shared.DisconnectAfterCancel = $false
        Set-ActionsEnabled -Enabled $true
    }
}
#endregion

<#
.SYNOPSIS
    Run one of the *-VPNCore functions on a background thread.
.DESCRIPTION
    The worker shares this script's session state, so $Script: variables and
    every automation function are the same objects the UI thread sees - there is
    nothing to re-host and no state to copy. What the worker must NOT do is
    touch a Windows Forms control directly; Write-Log, Update-UIState,
    Set-ActionsEnabled and Show-Balloon all marshal through Invoke-OnUI.

    A UI-thread timer reaps the worker when it finishes, so exceptions surface
    in the log instead of vanishing on a thread nobody is watching.
#>
function Start-VpnWorker {
    param([string]$Operation)   # "Connect" or "Disconnect"

    if ($Script:Worker) {
        Write-Log "A VPN operation is already running" "Yellow"
        return
    }

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $Script:WorkerRunspace
    $ps.AddScript("$Operation-VPNCore") | Out-Null

    $Script:Worker       = $ps
    $Script:WorkerHandle = $ps.BeginInvoke()

    # Poll for completion on the UI thread. This timer's tick is the only place
    # the worker is disposed, which keeps ownership in one place. It also mirrors
    # the shared flags back onto their $Script: counterparts so UI-thread code
    # can read them without reaching into the hashtable.
    $Script:WorkerPoll = New-Object System.Windows.Forms.Timer
    $Script:WorkerPoll.Interval = 200
    $Script:WorkerPoll.Add_Tick({
        if (-not $Script:WorkerHandle -or -not $Script:WorkerHandle.IsCompleted) { return }

        $Script:WorkerPoll.Stop()
        $Script:WorkerPoll.Dispose()
        $Script:WorkerPoll = $null

        try {
            $Script:Worker.EndInvoke($Script:WorkerHandle) | Out-Null

            # Errors raised inside the worker land here, not on a thread nobody
            # is watching.
            foreach ($e in $Script:Worker.Streams.Error) {
                Write-Log "Worker error: $($e.Exception.Message)" "Red"
                Update-UIState "Error"
            }
        } catch {
            Write-Log "Worker failed: $($_.Exception.Message)" "Red"
            Update-UIState "Error"
        } finally {
            $Script:Worker.Dispose()
            $Script:Worker = $null
            $Script:WorkerHandle = $null
        }

        # A disconnect requested mid-connect runs now, on a clean stack, with the
        # connect worker already reaped.
        if ($Script:Shared.DisconnectAfterCancel) {
            $Script:Shared.DisconnectAfterCancel = $false
            $Script:Shared.Cancel = $false
            Write-Log "Proceeding with requested disconnect..." "Yellow"
            Start-VpnWorker "Disconnect"
        }
    })
    $Script:WorkerPoll.Start()
}

<#
.SYNOPSIS
    Entry point for every Connect request (button, tray, auto-connect).
#>
function Connect-VPN {
    if ($Script:Shared.IsConnecting) {
        Write-Log "Connection already in progress..." "Yellow"
        return
    }
    if ($Script:Shared.IsDisconnecting) {
        Write-Log "Disconnect in progress - please wait" "Yellow"
        return
    }
    Start-VpnWorker "Connect"
}

<#
.SYNOPSIS
    Entry point for every Disconnect request.
.DESCRIPTION
    Pressed during a connect, this cancels it rather than racing it. The worker
    thread sees the flag at its next check and unwinds; its own finally block
    then performs the disconnect. We do not wait here - the handler returns
    immediately, and on the UI thread there is nothing to block anyway.
#>
function Disconnect-VPN {
    if ($Script:Shared.IsDisconnecting) {
        Write-Log "Disconnect already in progress..." "Yellow"
        return
    }

    if ($Script:Shared.IsConnecting) {
        Write-Log "Cancelling connect in progress..." "Yellow"
        $Script:Shared.Cancel = $true
        $Script:Shared.DisconnectAfterCancel = $true
        return
    }

    Start-VpnWorker "Disconnect"
}

#region [7] UI State Management
function Update-UIState {
    param([string]$State)

    if (-not $Script:MainForm -or $Script:MainForm.IsDisposed) { return }

    # State table: text, colour, and which buttons are usable.
    $green  = [System.Drawing.Color]::FromArgb(34, 197, 94)
    $red    = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $amber  = [System.Drawing.Color]::FromArgb(234, 179, 8)

    switch ($State) {
        "Connected"     { $text = "Connected";     $col = $green; $canConnect = $false; $canDisconnect = $true  }
        "Disconnected"  { $text = "Disconnected";  $col = $red;   $canConnect = $true;  $canDisconnect = $false }
        "Connecting"    { $text = "Connecting..."; $col = $amber; $canConnect = $false; $canDisconnect = $false }
        "Disconnecting" { $text = "Disconnecting..."; $col = $amber; $canConnect = $false; $canDisconnect = $false }
        "Error"         { $text = "Error";         $col = $red;   $canConnect = $true;  $canDisconnect = $false }
        default         { return }
    }

    # Capture into locals so the closure carries them; $Script: inside a
    # marshalled block resolves against the UI thread's scope, not the worker's.
    $lbl = $Script:StatusLabel; $ico = $Script:StatusIcon
    $cbtn = $Script:ConnectBtn; $dbtn = $Script:DisconnectBtn
    $tray = $Script:TrayIcon

    Invoke-OnUI {
        try {
            if ($lbl)  { $lbl.Text = $text; $lbl.ForeColor = $col }
            if ($ico)  { $ico.BackColor = $col }
            if ($cbtn) { $cbtn.Enabled = $canConnect }
            if ($dbtn) { $dbtn.Enabled = $canDisconnect }
            if ($tray) { $tray.Text = "AutoVPN - $text" }
        } catch {
            # Form not ready yet - ignore
        }
    }.GetNewClosure()
}
#endregion

#region [8] Settings Dialog
function Show-SettingsDialog {
    # This dialog is modal. Opened from inside a running sequence - which the
    # message pump makes possible - it would hold that sequence frozen mid-step
    # while its timeouts kept running against the wall clock.
    if ($Script:Shared.IsConnecting -or $Script:Shared.IsDisconnecting) {
        Write-Log "Settings unavailable while a VPN operation is running" "Yellow"
        return
    }

    $settingsForm = New-Object System.Windows.Forms.Form
    $settingsForm.Text = "AutoVPN Settings"
    $settingsForm.Size = New-Object System.Drawing.Size(420, 410)   # +30 for the auto-start checkbox
    $settingsForm.StartPosition = "CenterParent"
    $settingsForm.FormBorderStyle = "FixedDialog"
    $settingsForm.MaximizeBox = $false
    $settingsForm.MinimizeBox = $false
    $settingsForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $settingsForm.ForeColor = [System.Drawing.Color]::White
    $settingsForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $y = 15

    # VPN Client Path
    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = "VPN Client Path:"
    $lblPath.Location = New-Object System.Drawing.Point(15, $y)
    $lblPath.Size = New-Object System.Drawing.Size(370, 20)
    $settingsForm.Controls.Add($lblPath)
    $y += 22

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = New-Object System.Drawing.Point(15, $y)
    $txtPath.Size = New-Object System.Drawing.Size(305, 25)
    $txtPath.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $txtPath.ForeColor = [System.Drawing.Color]::White
    $txtPath.BorderStyle = "FixedSingle"
    $txtPath.Text = $Script:Config.vpn_client_path
    $settingsForm.Controls.Add($txtPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "..."
    $btnBrowse.Location = New-Object System.Drawing.Point(325, $y)
    $btnBrowse.Size = New-Object System.Drawing.Size(60, 25)
    $btnBrowse.FlatStyle = "Flat"
    $btnBrowse.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Executable (*.exe)|*.exe"
        $ofd.InitialDirectory = "C:\Program Files (x86)\VMware"
        if ($ofd.ShowDialog() -eq "OK") { $txtPath.Text = $ofd.FileName }
    })
    $settingsForm.Controls.Add($btnBrowse)
    $y += 35

    # Username
    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = "Username:"
    $lblUser.Location = New-Object System.Drawing.Point(15, $y)
    $lblUser.Size = New-Object System.Drawing.Size(370, 20)
    $settingsForm.Controls.Add($lblUser)
    $y += 22

    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(15, $y)
    $txtUser.Size = New-Object System.Drawing.Size(370, 25)
    $txtUser.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $txtUser.ForeColor = [System.Drawing.Color]::White
    $txtUser.BorderStyle = "FixedSingle"
    $settingsForm.Controls.Add($txtUser)
    $y += 35

    # Password
    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = "Password:"
    $lblPass.Location = New-Object System.Drawing.Point(15, $y)
    $lblPass.Size = New-Object System.Drawing.Size(370, 20)
    $settingsForm.Controls.Add($lblPass)
    $y += 22

    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = New-Object System.Drawing.Point(15, $y)
    $txtPass.Size = New-Object System.Drawing.Size(370, 25)
    $txtPass.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $txtPass.ForeColor = [System.Drawing.Color]::White
    $txtPass.BorderStyle = "FixedSingle"
    $txtPass.UseSystemPasswordChar = $true
    $settingsForm.Controls.Add($txtPass)
    $y += 40

    # Load existing credentials
    $existingCred = Load-VpnCredential
    if ($existingCred) {
        $txtUser.Text = $existingCred.Username
        $txtPass.Text = $existingCred.Password
    }

    # Auto-connect checkbox
    $chkAuto = New-Object System.Windows.Forms.CheckBox
    $chkAuto.Text = "Auto-connect when program starts"
    $chkAuto.Location = New-Object System.Drawing.Point(15, $y)
    $chkAuto.Size = New-Object System.Drawing.Size(370, 25)
    $chkAuto.ForeColor = [System.Drawing.Color]::White
    $chkAuto.Checked = $Script:Config.auto_connect
    $settingsForm.Controls.Add($chkAuto)
    $y += 28

    # Start-with-Windows checkbox. Previously there was none: the auto-connect
    # box above silently also controlled auto-start, so a user who wanted the
    # VPN to connect on launch had no way to avoid launching at logon too.
    $chkAutoStart = New-Object System.Windows.Forms.CheckBox
    $chkAutoStart.Text = "Start with Windows (hidden, at logon)"
    $chkAutoStart.Location = New-Object System.Drawing.Point(15, $y)
    $chkAutoStart.Size = New-Object System.Drawing.Size(370, 25)
    $chkAutoStart.ForeColor = [System.Drawing.Color]::White
    $chkAutoStart.Checked = (Test-AutoStart)
    $settingsForm.Controls.Add($chkAutoStart)
    $y += 28

    # Minimize to tray checkbox
    $chkTray = New-Object System.Windows.Forms.CheckBox
    $chkTray.Text = "Minimize to system tray"
    $chkTray.Location = New-Object System.Drawing.Point(15, $y)
    $chkTray.Size = New-Object System.Drawing.Size(370, 25)
    $chkTray.ForeColor = [System.Drawing.Color]::White
    $chkTray.Checked = $Script:Config.minimize_to_tray
    $settingsForm.Controls.Add($chkTray)
    $y += 35

    # Buttons
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(15, $y)
    $btnSave.Size = New-Object System.Drawing.Size(115, 35)
    $btnSave.FlatStyle = "Flat"
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(34, 197, 94)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnSave.Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtUser.Text) -or [string]::IsNullOrWhiteSpace($txtPass.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Please enter both username and password.", "AutoVPN", "OK", "Warning")
            return
        }

        # Save credentials
        Save-VpnCredential -Username $txtUser.Text -Password $txtPass.Text

        # Save config
        $Script:Config.vpn_client_path = $txtPath.Text
        $Script:Config.auto_connect = $chkAuto.Checked
        $Script:Config.minimize_to_tray = $chkTray.Checked
        Save-Config

        # Auto-start is its own setting, independent of auto-connect. Only touch
        # the scheduled task when the checkbox actually changed, so saving other
        # settings does not re-register it.
        if ($chkAutoStart.Checked -ne (Test-AutoStart)) {
            Set-AutoStart -Enable $chkAutoStart.Checked
        }

        Write-Log "Settings saved." "Green"
        $settingsForm.DialogResult = "OK"
        $settingsForm.Close()
    })
    $settingsForm.Controls.Add($btnSave)

    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = "Reset Credentials"
    $btnReset.Location = New-Object System.Drawing.Point(140, $y)
    $btnReset.Size = New-Object System.Drawing.Size(130, 35)
    $btnReset.FlatStyle = "Flat"
    $btnReset.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $btnReset.ForeColor = [System.Drawing.Color]::White
    $btnReset.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Delete saved credentials? You will need to enter them again.",
            "Reset Credentials", "YesNo", "Warning"
        )
        if ($confirm -eq "Yes") {
            Reset-VpnCredential
            $txtUser.Text = ""
            $txtPass.Text = ""
            $txtUser.Focus()
        }
    })
    $settingsForm.Controls.Add($btnReset)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(280, $y)
    $btnCancel.Size = New-Object System.Drawing.Size(105, 35)
    $btnCancel.FlatStyle = "Flat"
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.Add_Click({ $settingsForm.Close() })
    $settingsForm.Controls.Add($btnCancel)

    # Clear password from memory on close
    $settingsForm.Add_FormClosed({
        $txtPass.Text = ""
        $existingCred = $null
        [System.GC]::Collect()
    })

    $settingsForm.ShowDialog()
}
#endregion

#region [9] Auto-Start Management
# Name of the logon task. Kept in one place because both Set-AutoStart and
# Test-AutoStart look it up, and a mismatch would silently orphan a task.
$Script:TaskName = "AutoVPN"

<#
.SYNOPSIS
    What auto-start would launch: the exe if this is a compiled build,
    otherwise PowerShell running the script.
.DESCRIPTION
    Returns a hashtable with Path and Arguments, or $null if nothing suitable
    exists. Deliberately does NOT use app.bat: the batch file hardcodes an
    absolute script path, so a copy of the project in another folder would
    launch the wrong one.
#>
function Get-AutoStartCommand {
    $exe = Join-Path $Script:ScriptDir "AutoVPN.exe"
    $ps1 = Join-Path $Script:ScriptDir "AutoVPN.ps1"

    # Prefer the exe when this is a compiled build: it is self-contained, so a
    # machine can run AutoVPN without shipping the source alongside it.
    $running = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $isCompiled = ($running -match '\.exe$') -and ($running -notmatch 'powershell\.exe$|pwsh\.exe$')

    if ($isCompiled -and (Test-Path $exe)) {
        return @{ Path = $exe; Arguments = "-Background" }
    }
    if (Test-Path $ps1) {
        return @{
            Path      = (Get-Command powershell.exe).Source
            Arguments = "-ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ps1`" -Background"
        }
    }
    if (Test-Path $exe) {
        return @{ Path = $exe; Arguments = "-Background" }
    }
    return $null
}

<#
.SYNOPSIS
    True if the logon task exists.
#>
function Test-AutoStart {
    try {
        return $null -ne (Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Create or remove the hidden logon task that starts AutoVPN.
.DESCRIPTION
    Replaces the old Startup-folder shortcut, which flashed a console window and
    pointed at app.bat's hardcoded path. A scheduled task starts hidden, runs in
    the interactive session (required - SVPClient's windows do not exist in
    session 0), and is easier to inspect and remove.

    Registered for the current user only, at their own privilege level. It is
    NOT "run whether logged on or not": the automation drives a GUI application
    and needs a real desktop.

    Removes a leftover Startup shortcut from earlier versions so the two cannot
    both fire.
#>
function Set-AutoStart {
    param([bool]$Enable)

    # Earlier versions used a Startup-folder shortcut. Clear it either way, so
    # enabling the task never leaves two launchers racing each other.
    $legacyShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "AutoVPN.lnk"
    if (Test-Path $legacyShortcut) {
        try {
            Remove-Item $legacyShortcut -Force
            Write-Log "Removed old Startup shortcut (replaced by scheduled task)" "Yellow"
        } catch {
            Write-Log "Could not remove old Startup shortcut: $($_.Exception.Message)" "Yellow"
        }
    }

    if (-not $Enable) {
        try {
            if (Test-AutoStart) {
                Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction Stop
                Write-Log "Auto-start disabled (task removed)" "Yellow"
            }
        } catch {
            Write-Log "Could not remove auto-start task: $($_.Exception.Message)" "Red"
        }
        return
    }

    $cmd = Get-AutoStartCommand
    if (-not $cmd) {
        Write-Log "Auto-start not enabled: neither AutoVPN.exe nor AutoVPN.ps1 found in $Script:ScriptDir" "Red"
        return
    }

    try {
        $action = if ($cmd.Arguments) {
            New-ScheduledTaskAction -Execute $cmd.Path -Argument $cmd.Arguments -WorkingDirectory $Script:ScriptDir
        } else {
            New-ScheduledTaskAction -Execute $cmd.Path -WorkingDirectory $Script:ScriptDir
        }

        $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

        # Hidden, and none of the defaults that would stop a long-running tray
        # app: no execution time limit, do not stop on battery, do not refuse to
        # start on battery.
        $settings = New-ScheduledTaskSettingsSet -Hidden `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -StartWhenAvailable

        # Interactive: the automation drives SVPClient's windows, which only
        # exist on the logged-on user's desktop.
        $principal = New-ScheduledTaskPrincipal `
            -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
            -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $Script:TaskName `
            -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description "Starts AutoVPN at logon, hidden. Created by AutoVPN Settings." `
            -Force -ErrorAction Stop | Out-Null

        Write-Log "Auto-start enabled (hidden logon task '$($Script:TaskName)')" "Green"
    } catch {
        Write-Log "Could not create auto-start task: $($_.Exception.Message)" "Red"
        Write-Log "Task creation can require permission your account may not have" "Yellow"
    }
}
#endregion

#region [10] Main GUI
function Build-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "AutoVPN v2.0"
    $form.Size = New-Object System.Drawing.Size(400, 480)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # ---- Header ----
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Location = New-Object System.Drawing.Point(0, 0)
    $headerPanel.Size = New-Object System.Drawing.Size(400, 60)
    $headerPanel.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $form.Controls.Add($headerPanel)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "AutoVPN"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Location = New-Object System.Drawing.Point(15, 8)
    $titleLabel.Size = New-Object System.Drawing.Size(150, 40)
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $headerPanel.Controls.Add($titleLabel)

    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = "v2.0 | VMware SSL VPN-Plus"
    $versionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $versionLabel.Location = New-Object System.Drawing.Point(155, 18)
    $versionLabel.Size = New-Object System.Drawing.Size(200, 20)
    $versionLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
    $headerPanel.Controls.Add($versionLabel)

    # ---- Status Section ----
    $statusPanel = New-Object System.Windows.Forms.Panel
    $statusPanel.Location = New-Object System.Drawing.Point(15, 75)
    $statusPanel.Size = New-Object System.Drawing.Size(355, 50)
    $statusPanel.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $form.Controls.Add($statusPanel)

    # Status dot
    $Script:StatusIcon = New-Object System.Windows.Forms.Panel
    $Script:StatusIcon.Location = New-Object System.Drawing.Point(15, 17)
    $Script:StatusIcon.Size = New-Object System.Drawing.Size(16, 16)
    $Script:StatusIcon.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $statusPanel.Controls.Add($Script:StatusIcon)

    $Script:StatusLabel = New-Object System.Windows.Forms.Label
    $Script:StatusLabel.Text = "Disconnected"
    $Script:StatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $Script:StatusLabel.Location = New-Object System.Drawing.Point(40, 10)
    $Script:StatusLabel.Size = New-Object System.Drawing.Size(300, 30)
    $Script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $statusPanel.Controls.Add($Script:StatusLabel)

    # ---- Connection name ----
    $connLabel = New-Object System.Windows.Forms.Label
    $connLabel.Text = "Network: $($Script:Config.connection_name)"
    $connLabel.Location = New-Object System.Drawing.Point(15, 135)
    $connLabel.Size = New-Object System.Drawing.Size(355, 20)
    $connLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
    $form.Controls.Add($connLabel)

    # ---- Buttons ----
    $Script:ConnectBtn = New-Object System.Windows.Forms.Button
    $Script:ConnectBtn.Text = "Connect VPN"
    $Script:ConnectBtn.Location = New-Object System.Drawing.Point(15, 165)
    $Script:ConnectBtn.Size = New-Object System.Drawing.Size(170, 40)
    $Script:ConnectBtn.FlatStyle = "Flat"
    $Script:ConnectBtn.BackColor = [System.Drawing.Color]::FromArgb(34, 197, 94)
    $Script:ConnectBtn.ForeColor = [System.Drawing.Color]::White
    $Script:ConnectBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $Script:ConnectBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Script:ConnectBtn.Add_Click({
        Connect-VPN
    })
    $form.Controls.Add($Script:ConnectBtn)

    $Script:DisconnectBtn = New-Object System.Windows.Forms.Button
    $Script:DisconnectBtn.Text = "Disconnect"
    $Script:DisconnectBtn.Location = New-Object System.Drawing.Point(195, 165)
    $Script:DisconnectBtn.Size = New-Object System.Drawing.Size(175, 40)
    $Script:DisconnectBtn.FlatStyle = "Flat"
    $Script:DisconnectBtn.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $Script:DisconnectBtn.ForeColor = [System.Drawing.Color]::White
    $Script:DisconnectBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $Script:DisconnectBtn.Enabled = $false
    $Script:DisconnectBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Script:DisconnectBtn.Add_Click({
        Disconnect-VPN
    })
    $form.Controls.Add($Script:DisconnectBtn)

    # Settings button
    $settingsBtn = New-Object System.Windows.Forms.Button
    $Script:SettingsBtn = $settingsBtn
    $settingsBtn.Text = "Settings"
    $settingsBtn.Location = New-Object System.Drawing.Point(15, 215)
    $settingsBtn.Size = New-Object System.Drawing.Size(355, 30)
    $settingsBtn.FlatStyle = "Flat"
    $settingsBtn.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
    $settingsBtn.ForeColor = [System.Drawing.Color]::White
    $settingsBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $settingsBtn.Add_Click({ Show-SettingsDialog })
    $form.Controls.Add($settingsBtn)

    # ---- Log Area ----
    $logLabel = New-Object System.Windows.Forms.Label
    $logLabel.Text = "Log:"
    $logLabel.Location = New-Object System.Drawing.Point(15, 255)
    $logLabel.Size = New-Object System.Drawing.Size(355, 18)
    $logLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
    $form.Controls.Add($logLabel)

    $Script:LogBox = New-Object System.Windows.Forms.TextBox
    $Script:LogBox.Multiline = $true
    $Script:LogBox.ScrollBars = "Vertical"
    $Script:LogBox.ReadOnly = $true
    $Script:LogBox.Location = New-Object System.Drawing.Point(15, 275)
    $Script:LogBox.Size = New-Object System.Drawing.Size(355, 150)
    $Script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(15, 15, 15)
    $Script:LogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $Script:LogBox.Font = New-Object System.Drawing.Font("Consolas", 8)
    $Script:LogBox.BorderStyle = "FixedSingle"
    $form.Controls.Add($Script:LogBox)

    # ---- System Tray ----
    $Script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $Script:TrayIcon.Text = "AutoVPN - Disconnected"
    $Script:TrayIcon.Visible = $true

    # Create a simple icon from drawing
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.FillEllipse([System.Drawing.Brushes]::DodgerBlue, 2, 2, 12, 12)
    $g.Dispose()
    $Script:TrayIcon.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $trayConnect = $trayMenu.Items.Add("Connect VPN")
    $Script:TrayConnect = $trayConnect
    $trayConnect.Add_Click({
        $Script:MainForm.Show()
        $Script:MainForm.WindowState = "Normal"
        Connect-VPN
    })
    $trayDisconnect = $trayMenu.Items.Add("Disconnect")
    $Script:TrayDisconnect = $trayDisconnect
    $trayDisconnect.Add_Click({
        Disconnect-VPN
    })
    $trayMenu.Items.Add("-") | Out-Null
    $traySettings = $trayMenu.Items.Add("Settings")
    $Script:TraySettings = $traySettings
    $traySettings.Add_Click({
        $Script:MainForm.Show()
        $Script:MainForm.WindowState = "Normal"
        Show-SettingsDialog
    })
    $trayMenu.Items.Add("-") | Out-Null
    $trayShow = $trayMenu.Items.Add("Show Window")
    $trayShow.Add_Click({
        $Script:MainForm.Show()
        $Script:MainForm.WindowState = "Normal"
        [Win32]::SetForegroundWindow($Script:MainForm.Handle) | Out-Null
    })
    $trayExit = $trayMenu.Items.Add("Exit")
    $trayExit.Add_Click({
        $Script:TrayIcon.Visible = $false
        $Script:MainForm.Close()
    })
    $Script:TrayIcon.ContextMenuStrip = $trayMenu

    $Script:TrayIcon.Add_DoubleClick({
        $Script:MainForm.Show()
        $Script:MainForm.WindowState = "Normal"
        [Win32]::SetForegroundWindow($Script:MainForm.Handle) | Out-Null
    })

    # Minimize to tray behavior
    $form.Add_Resize({
        if ($Script:Config.minimize_to_tray -and $Script:MainForm.WindowState -eq "Minimized") {
            $Script:MainForm.Hide()
        }
    })

    # Cleanup on close
    $form.Add_FormClosing({
        # Ask any running sequence to stop, then give it a moment. The UI thread
        # is about to go away, and Invoke-OnUI calls from the worker would throw
        # once it does.
        $Script:Shared.Cancel = $true
        if ($Script:WorkerHandle -and -not $Script:WorkerHandle.IsCompleted) {
            $Script:WorkerHandle.AsyncWaitHandle.WaitOne(3000) | Out-Null
        }
        if ($Script:WorkerPoll) { try { $Script:WorkerPoll.Stop(); $Script:WorkerPoll.Dispose() } catch { } }
        if ($Script:Worker)     { try { $Script:Worker.Dispose() } catch { } }
        if ($Script:WorkerRunspace) { try { $Script:WorkerRunspace.Close(); $Script:WorkerRunspace.Dispose() } catch { } }

        $Script:TrayIcon.Visible = $false
        $Script:TrayIcon.Dispose()
    })

    $Script:MainForm = $form
    return $form
}
#endregion

#region [11] Main Entry Point
function Main {
    # Load config
    Load-Config | Out-Null

    # Build GUI
    $form = Build-MainForm

    # Create the worker runspace once and reuse it; each operation gets its own
    # PowerShell instance pointed at it. Built after the form so the worker can
    # be handed the form handle it marshals through.
    $Script:WorkerRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host)
    $Script:WorkerRunspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $Script:WorkerRunspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $Script:WorkerRunspace.Open()

    # A new runspace starts empty - it does not inherit this script's functions.
    # Feed it every function definition currently loaded here, plus the shared
    # state and the config the automation reads. $Script: inside those functions
    # resolves to the worker's own scope, so anything both threads must see
    # lives in $Script:Shared, which is the same object on both sides.
    $bootstrap = New-Object System.Text.StringBuilder
    foreach ($fn in Get-ChildItem Function: | Where-Object { $_.Source -eq '' -or -not $_.Source }) {
        if ($fn.Name -match '^(Connect|Disconnect|Find|Click|Handle|Fill|Test|Start|Dismiss|Write|Update|Set|Show|Invoke|Load|Save|Reset|Get|DoEvents)-') {
            [void]$bootstrap.AppendLine("function $($fn.Name) {")
            [void]$bootstrap.AppendLine($fn.Definition)
            [void]$bootstrap.AppendLine("}")
        }
    }

    $init = [System.Management.Automation.PowerShell]::Create()
    $init.Runspace = $Script:WorkerRunspace
    $init.AddScript($bootstrap.ToString()) | Out-Null
    $init.Invoke() | Out-Null
    if ($init.Streams.Error.Count) {
        Write-Log "Worker bootstrap: $($init.Streams.Error[0].Exception.Message)" "Yellow"
    }
    $init.Dispose()

    # Bind the worker's own $Script: scope to the objects it needs. $Script:Shared
    # is deliberately the SAME synchronized hashtable instance both threads use -
    # that is the entire channel between them. The form reference lets the
    # worker's Invoke-OnUI marshal back here; the rest are read-only inputs.
    $bind = [System.Management.Automation.PowerShell]::Create()
    $bind.Runspace = $Script:WorkerRunspace
    $bind.AddScript(@'
param($shared, $config, $dir, $form, $ui)
$Script:Shared    = $shared
$Script:Config    = $config
$Script:ScriptDir = $dir
$Script:MainForm  = $form
$Script:LogBox         = $ui.LogBox
$Script:StatusLabel    = $ui.StatusLabel
$Script:StatusIcon     = $ui.StatusIcon
$Script:ConnectBtn     = $ui.ConnectBtn
$Script:DisconnectBtn  = $ui.DisconnectBtn
$Script:TrayIcon       = $ui.TrayIcon
$Script:SettingsBtn    = $ui.SettingsBtn
$Script:TrayConnect    = $ui.TrayConnect
$Script:TrayDisconnect = $ui.TrayDisconnect
$Script:TraySettings   = $ui.TraySettings
'@) | Out-Null
    $bind.AddArgument($Script:Shared) | Out-Null
    $bind.AddArgument($Script:Config) | Out-Null
    $bind.AddArgument($Script:ScriptDir) | Out-Null
    $bind.AddArgument($form) | Out-Null
    # The control references themselves. The worker never touches these directly
    # - every access goes through Invoke-OnUI, which marshals to the UI thread -
    # but it needs the references to have something to marshal.
    $bind.AddArgument(@{
        LogBox = $Script:LogBox; StatusLabel = $Script:StatusLabel
        StatusIcon = $Script:StatusIcon; ConnectBtn = $Script:ConnectBtn
        DisconnectBtn = $Script:DisconnectBtn; TrayIcon = $Script:TrayIcon
        SettingsBtn = $Script:SettingsBtn; TrayConnect = $Script:TrayConnect
        TrayDisconnect = $Script:TrayDisconnect; TraySettings = $Script:TraySettings
    }) | Out-Null
    $bind.Invoke() | Out-Null
    if ($bind.Streams.Error.Count) {
        Write-Log "Worker bind: $($bind.Streams.Error[0].Exception.Message)" "Yellow"
    }
    $bind.Dispose()


    Write-Log "AutoVPN v2.0 started" "Cyan"
    Write-Log "Network: $($Script:Config.connection_name)" "White"

    # Read the switch, and fall back to the raw command line. Both work in a
    # PS2EXE build - measured - so this is belt and braces rather than a
    # workaround. Determined here because the credentials check below needs it.
    $wantBackground = $Background -or ([Environment]::CommandLine -match '(?i)(^|\s)[-/]Background(\s|$)')

    # Check if credentials exist
    if (-not (Test-VpnCredential)) {
        if ($wantBackground) {
            # Started by the logon task with nothing configured. Opening a modal
            # Settings dialog nobody asked for would defeat the point of running
            # hidden, so sit in the tray and let the user open Settings when they
            # are ready.
            Write-Log "No credentials found - configure via the tray icon" "Yellow"
        } else {
            Write-Log "No credentials found - opening Settings..." "Yellow"
            # Use timer to show settings after form is shown
            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 500
            $timer.Add_Tick({
                $timer.Stop()
                $timer.Dispose()
                Show-SettingsDialog
            })
            $timer.Start()
        }
    } else {
        Write-Log "Credentials loaded" "Green"

        # Auto-connect if enabled
        if ($Script:Config.auto_connect) {
            Write-Log "Auto-connect enabled - connecting..." "Yellow"
            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 1000
            $timer.Add_Tick({
                $timer.Stop()
                $timer.Dispose()
                Connect-VPN
            })
            $timer.Start()
        }
    }

    # Check current VPN status using adapter detection
    if (Test-VpnConnectedNow) {
        Update-UIState "Connected"
        Write-Log "VPN is currently connected" "Green"
    }

    [System.Windows.Forms.Application]::EnableVisualStyles()

    if ($wantBackground) {
        # Started by the logon task: live in the tray, show no window. The form
        # still has to exist - it owns the tray icon and is what Invoke-OnUI
        # marshals through - so it is created and then hidden.
        Write-Log "Started in background mode (tray only)" "Cyan"
        $form.ShowInTaskbar = $false

        # Hide with ShowWindow(SW_HIDE) from a short timer, so it runs AFTER the
        # message loop has started and the handle exists. Add_Shown + Form.Hide()
        # was tried first and works as a .ps1 but leaves the window visible in a
        # compiled build; this fires later and works in both. Capture the form in
        # a local - $Script:MainForm resolves against the handler's own scope.
        $bgForm = $form

        # Hide repeatedly for the first few seconds rather than once. A single
        # well-timed hide worked in isolation but not in the full application,
        # and the cause was not identified after extended testing; something
        # during startup puts the window back. Re-hiding until the app has
        # settled is not elegant, but it is reliable, and it stops as soon as the
        # window stays hidden.
        $script:hideTries = 0
        $hideTimer = New-Object System.Windows.Forms.Timer
        $hideTimer.Interval = 150
        $hideTimer.Add_Tick({
            $script:hideTries++
            if ($bgForm.IsDisposed) { $hideTimer.Stop(); $hideTimer.Dispose(); return }

            [Win32]::ShowWindow($bgForm.Handle, [Win32]::SW_HIDE) | Out-Null
            $bgForm.ShowInTaskbar = $false

            # ~4.5 s of retries, then give up so this never runs forever.
            if ($script:hideTries -ge 30) {
                $hideTimer.Stop()
                $hideTimer.Dispose()
            }
        }.GetNewClosure())
        $hideTimer.Start()
    }

    [System.Windows.Forms.Application]::Run($form)
}

# Ensure STA thread for Windows Forms
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    try { [Console]::WriteLine("[WARN] Not in STA mode - restarting in STA...") } catch { }
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    # Carry our own switches across the relaunch. Without this, a run started by
    # the logon task would lose -Background and pop a window at every logon.
    $passthru = if ($Background -or ([Environment]::CommandLine -match '(?i)(^|\s)[-/]Background(\s|$)')) { " -Background" } else { "" }

    if ($exePath -match 'powershell\.exe$|pwsh\.exe$') {
        # Running as .ps1 - relaunch with -STA
        $scriptPath = $MyInvocation.MyCommand.Definition
        Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$scriptPath`"$passthru"
    } else {
        # Running as .exe - relaunch self
        if ($passthru) { Start-Process -FilePath $exePath -ArgumentList $passthru.Trim() }
        else           { Start-Process -FilePath $exePath }
    }
    exit
}

# Run the application
try {
    Main
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "AutoVPN Error: $($_.Exception.Message)`n`n$($_.ScriptStackTrace)",
        "AutoVPN Error", "OK", "Error"
    )
}
#endregion
