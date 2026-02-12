# ============================================================================
# AutoVPN v2.0 - VMware SSL VPN-Plus Auto-Connect
# ============================================================================
# GUI application for one-click VPN connection with saved credentials.
# Uses Win32 Messages (GetDlgItem + SendMessage) instead of SendKeys
# for reliable, focus-independent automation.
# ============================================================================

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

    // Window state
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
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
    public const int  SW_SHOW       = 5;
    public const int  SW_RESTORE    = 9;

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

    /// <summary>Click a button by sending BM_CLICK, with WM_COMMAND fallback</summary>
    public static bool ClickButton(IntPtr parent, int controlId) {
        IntPtr btn = GetDlgItem(parent, controlId);
        if (btn == IntPtr.Zero) return false;

        // Primary: BM_CLICK
        SendMessage(btn, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
        return true;
    }

    /// <summary>Set text on a control via WM_SETTEXT</summary>
    public static bool SetText(IntPtr parent, int controlId, string text) {
        IntPtr ctrl = GetDlgItem(parent, controlId);
        if (ctrl == IntPtr.Zero) return false;
        SendMessage(ctrl, WM_SETTEXT, IntPtr.Zero, text);
        return true;
    }

    /// <summary>Get text from a control via WM_GETTEXT</summary>
    public static string GetText(IntPtr hwnd) {
        int len = (int)SendMessage(hwnd, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero);
        if (len <= 0) return "";
        StringBuilder sb = new StringBuilder(len + 1);
        SendMessage(hwnd, WM_GETTEXT, (IntPtr)(len + 1), sb.ToString());
        return sb.ToString();
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
$Script:IsConnecting = $false
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
function Write-Log {
    param([string]$Message, [string]$Color = "White")

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message"

    if ($Script:LogBox -and -not $Script:LogBox.IsDisposed) {
        try {
            $Script:LogBox.AppendText("$line`r`n")
            $Script:LogBox.SelectionStart = $Script:LogBox.TextLength
            $Script:LogBox.ScrollToCaret()
        } catch {
            # Form not ready yet - ignore
        }
    }

    Write-Host $line -ForegroundColor $Color
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

    # Make window visible
    [Win32]::ShowWindow($LoginWindowHwnd, [Win32]::SW_RESTORE) | Out-Null
    Start-Sleep -Milliseconds 300

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
        $hwnd = [Win32]::FindWindowByTitle("Security Alert")
        if ($hwnd -ne [IntPtr]::Zero) {
            Write-Log "Found Security Alert dialog (HWND: $($hwnd.ToInt64()))" "Yellow"

            # Enumerate buttons to find "Yes" (typically IDYES = 6)
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
                [Win32]::SendMessage($yesBtn.Handle, [Win32]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                Write-Log "Security Alert accepted" "Green"
                return $true
            } else {
                # Try standard IDYES = 6 via GetDlgItem
                $yesBtnHwnd = [Win32]::GetDlgItem($hwnd, 6)
                if ($yesBtnHwnd -ne [IntPtr]::Zero) {
                    Write-Log "Clicking Yes (ID=6) on Security Alert..." "Yellow"
                    [Win32]::SendMessage($yesBtnHwnd, [Win32]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
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
        # Also handle Security Alert if it pops up during wait
        $secHwnd = [Win32]::FindWindowByTitle("Security Alert")
        if ($secHwnd -ne [IntPtr]::Zero) {
            Handle-SecurityAlert -TimeoutSeconds 5
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

    if ($editControls.Count -lt 2) {
        Write-Log "ERROR: Expected 2 Edit controls (user/pass), found $($editControls.Count)" "Red"
        return $false
    }

    # First Edit = Username, Second Edit = Password
    $userCtrl = $editControls[0]
    $passCtrl = $editControls[1]

    Write-Log "Setting username..." "Yellow"
    [Win32]::SendMessage($userCtrl.Handle, [Win32]::WM_SETTEXT, [IntPtr]::Zero, $Username) | Out-Null
    Start-Sleep -Milliseconds 200

    Write-Log "Setting password..." "Yellow"
    [Win32]::SendMessage($passCtrl.Handle, [Win32]::WM_SETTEXT, [IntPtr]::Zero, $Password) | Out-Null
    Start-Sleep -Milliseconds 200

    # Find OK button
    $okBtn = $buttonControls | Where-Object { $_.Text -match "OK|Login|Submit|Connect" -or $_.ControlId -eq 1 } | Select-Object -First 1
    if (-not $okBtn) {
        # Fallback: first enabled button
        $okBtn = $buttonControls | Where-Object { $_.IsEnabled } | Select-Object -First 1
    }

    if ($okBtn) {
        Write-Log "Clicking OK button (ID: $($okBtn.ControlId), Text: '$($okBtn.Text)')..." "Yellow"
        [Win32]::SendMessage($okBtn.Handle, [Win32]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
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
        $hwnd = [Win32]::FindWindowByTitle("SSL VPN-Plus Client")
        if ($hwnd -ne [IntPtr]::Zero) {
            # Check if this is the notification dialog (has OK button with ID=1 or ID=2)
            $okBtn = [Win32]::GetDlgItem($hwnd, 2)  # IDOK = 2 for info dialogs
            if ($okBtn -eq [IntPtr]::Zero) {
                $okBtn = [Win32]::GetDlgItem($hwnd, 1)  # IDOK = 1
            }
            if ($okBtn -ne [IntPtr]::Zero) {
                Write-Log "Dismissing SVPClient notification..." "Yellow"
                [Win32]::SendMessage($okBtn, [Win32]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                Write-Log "Notification dismissed" "Green"
                return
            }
        }
        DoEvents-Sleep 1000
    }
}

function DoEvents-Sleep {
    param([int]$Milliseconds)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function Connect-VPN {
    if ($Script:IsConnecting) {
        Write-Log "Connection already in progress..." "Yellow"
        return
    }

    $Script:IsConnecting = $true
    Update-UIState "Connecting"

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
        [System.Windows.Forms.Application]::DoEvents()
        if (-not (Start-SVPClient)) {
            Update-UIState "Error"
            return
        }

        DoEvents-Sleep 2000

        # Step 2: Find Login window
        Write-Log "Step 2: Finding Login window..." "Yellow"
        [System.Windows.Forms.Application]::DoEvents()
        $loginResult = Find-SVPLoginWindow -TimeoutSeconds 15
        if ($loginResult.Status -eq "connected") {
            Update-UIState "Connected"
            return
        }
        if ($loginResult.Status -eq "timeout") {
            Update-UIState "Error"
            return
        }
        $loginHwnd = $loginResult.Handle

        # Step 3: Click Login button
        Write-Log "Step 3: Clicking Login..." "Yellow"
        [System.Windows.Forms.Application]::DoEvents()
        if (-not (Click-LoginButton -LoginWindowHwnd $loginHwnd)) {
            Update-UIState "Error"
            return
        }

        DoEvents-Sleep 2000

        # Step 4: Handle Security Alert (certificate dialog)
        Write-Log "Step 4: Checking for Security Alert..." "Yellow"
        [System.Windows.Forms.Application]::DoEvents()
        Handle-SecurityAlert -TimeoutSeconds 10

        DoEvents-Sleep 1000

        # Step 5: Find Auth window
        Write-Log "Step 5: Waiting for Authentication..." "Yellow"
        [System.Windows.Forms.Application]::DoEvents()
        $authHwnd = Find-AuthWindow -TimeoutSeconds 20

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
            if ($Script:TrayIcon) {
                $Script:TrayIcon.BalloonTipTitle = "AutoVPN"
                $Script:TrayIcon.BalloonTipText = "VPN Connected"
                $Script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
                $Script:TrayIcon.ShowBalloonTip(3000)
            }
            return
        }

        # Step 6: Fill auth form
        Write-Log "Step 6: Filling credentials..." "Yellow"
        [System.Windows.Forms.Application]::DoEvents()
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
        [System.Windows.Forms.Application]::DoEvents()
        DoEvents-Sleep 3000
        if (Test-VpnConnected -TimeoutSeconds 30) {
            Update-UIState "Connected"

            # Auto-dismiss "connection established" notification from SVPClient
            Dismiss-SVPNotification

            if ($Script:TrayIcon) {
                $Script:TrayIcon.BalloonTipTitle = "AutoVPN"
                $Script:TrayIcon.BalloonTipText = "VPN Connected"
                $Script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
                $Script:TrayIcon.ShowBalloonTip(3000)
            }
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
        $Script:IsConnecting = $false
    }
}

function Disconnect-VPN {
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
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c taskkill /F /IM SVPClient.exe"
        $psi.Verb = "runas"
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $elevatedProc = [System.Diagnostics.Process]::Start($psi)
        Write-Log "UAC accepted, killing SVPClient..." "Yellow"
        [System.Windows.Forms.Application]::DoEvents()
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
            if ($Script:TrayIcon) {
                $Script:TrayIcon.BalloonTipTitle = "AutoVPN"
                $Script:TrayIcon.BalloonTipText = "VPN Disconnected"
                $Script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
                $Script:TrayIcon.ShowBalloonTip(3000)
            }
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
}
#endregion

#region [7] UI State Management
function Update-UIState {
    param([string]$State)

    if (-not $Script:MainForm -or $Script:MainForm.IsDisposed) { return }

    try {
        switch ($State) {
            "Connected" {
                $Script:StatusLabel.Text = "Connected"
                $Script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(34, 197, 94)
                $Script:StatusIcon.BackColor = [System.Drawing.Color]::FromArgb(34, 197, 94)
                $Script:ConnectBtn.Enabled = $false
                $Script:DisconnectBtn.Enabled = $true
                if ($Script:TrayIcon) { $Script:TrayIcon.Text = "AutoVPN - Connected" }
            }
            "Disconnected" {
                $Script:StatusLabel.Text = "Disconnected"
                $Script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
                $Script:StatusIcon.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
                $Script:ConnectBtn.Enabled = $true
                $Script:DisconnectBtn.Enabled = $false
                if ($Script:TrayIcon) { $Script:TrayIcon.Text = "AutoVPN - Disconnected" }
            }
            "Connecting" {
                $Script:StatusLabel.Text = "Connecting..."
                $Script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(234, 179, 8)
                $Script:StatusIcon.BackColor = [System.Drawing.Color]::FromArgb(234, 179, 8)
                $Script:ConnectBtn.Enabled = $false
                $Script:DisconnectBtn.Enabled = $false
                if ($Script:TrayIcon) { $Script:TrayIcon.Text = "AutoVPN - Connecting..." }
            }
            "Disconnecting" {
                $Script:StatusLabel.Text = "Disconnecting..."
                $Script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(234, 179, 8)
                $Script:StatusIcon.BackColor = [System.Drawing.Color]::FromArgb(234, 179, 8)
                $Script:ConnectBtn.Enabled = $false
                $Script:DisconnectBtn.Enabled = $false
            }
            "Error" {
                $Script:StatusLabel.Text = "Error"
                $Script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
                $Script:StatusIcon.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
                $Script:ConnectBtn.Enabled = $true
                $Script:DisconnectBtn.Enabled = $false
                if ($Script:TrayIcon) { $Script:TrayIcon.Text = "AutoVPN - Error" }
            }
        }
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        # Form not ready yet - ignore
    }
}
#endregion

#region [8] Settings Dialog
function Show-SettingsDialog {
    $settingsForm = New-Object System.Windows.Forms.Form
    $settingsForm.Text = "AutoVPN Settings"
    $settingsForm.Size = New-Object System.Drawing.Size(420, 380)
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

        # Handle auto-start shortcut
        Set-AutoStart -Enable $chkAuto.Checked

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
function Set-AutoStart {
    param([bool]$Enable)

    $startupFolder = [Environment]::GetFolderPath("Startup")
    $shortcutPath = Join-Path $startupFolder "AutoVPN.lnk"

    if ($Enable) {
        $batPath = Join-Path $Script:ScriptDir "app.bat"
        if (Test-Path $batPath) {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $batPath
            $shortcut.WorkingDirectory = $Script:ScriptDir
            $shortcut.WindowStyle = 7  # Minimized
            $shortcut.Description = "AutoVPN - Auto-connect VPN"
            $shortcut.Save()
            Write-Log "Auto-start enabled (shortcut created)" "Green"
        }
    } else {
        if (Test-Path $shortcutPath) {
            Remove-Item $shortcutPath -Force
            Write-Log "Auto-start disabled (shortcut removed)" "Yellow"
        }
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
    $trayConnect.Add_Click({
        $Script:MainForm.Show()
        $Script:MainForm.WindowState = "Normal"
        Connect-VPN
    })
    $trayDisconnect = $trayMenu.Items.Add("Disconnect")
    $trayDisconnect.Add_Click({
        Disconnect-VPN
    })
    $trayMenu.Items.Add("-") | Out-Null
    $traySettings = $trayMenu.Items.Add("Settings")
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

    Write-Log "AutoVPN v2.0 started" "Cyan"
    Write-Log "Network: $($Script:Config.connection_name)" "White"

    # Check if credentials exist
    if (-not (Test-VpnCredential)) {
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
    [System.Windows.Forms.Application]::Run($form)
}

# Ensure STA thread for Windows Forms
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "[WARN] Not in STA mode - restarting in STA..." -ForegroundColor Yellow
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exePath -match 'powershell\.exe$|pwsh\.exe$') {
        # Running as .ps1 - relaunch with -STA
        $scriptPath = $MyInvocation.MyCommand.Definition
        Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$scriptPath`""
    } else {
        # Running as .exe - relaunch self
        Start-Process -FilePath $exePath
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
