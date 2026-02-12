# AutoVPN v2.0

One-click VPN auto-connect for **VMware SSL VPN-Plus Client** with credential save and GUI.

## Features

- **One-click Connect/Disconnect** - No manual credential entry after first setup
- **Secure Credential Storage** - DPAPI encryption (Windows Data Protection API, per-user per-machine)
- **Dark-themed GUI** - Clean Windows Forms interface with real-time status and activity log
- **System Tray** - Minimize to tray, tray context menu, balloon notifications
- **Auto-connect** - Option to connect VPN automatically on program startup
- **Auto-start** - Option to launch with Windows (Startup folder shortcut)
- **Smart Detection** - Detects VPN status via network adapter, handles Security Alert dialogs automatically

## Screenshots

```
+----------------------------------+
|  AutoVPN               v2.0     |
|  ================================|
|  [*] Connected                   |
|  Network: ADA-VPN                |
|  [Connect VPN]  [Disconnect]     |
|  [        Settings         ]     |
|  Log:                            |
|  [14:00:01] VPN Connected!       |
+----------------------------------+
```

## Requirements

- Windows 10+
- PowerShell 5.1+
- VMware SSL VPN-Plus Client (v6.3.0 or compatible)
- Administrator privileges (for disconnect only)

## Installation

1. Clone the repository:
   ```
   git clone https://github.com/Riveany/SecureVPN.git
   ```

2. Run `app.bat` (or create a shortcut to it)

3. On first launch, **Settings** dialog opens automatically - enter your VPN username and password, then click **Save**

4. Click **Connect VPN**

## Files

| File | Description |
|------|-------------|
| `app.bat` | Launcher - runs PowerShell with required flags |
| `AutoVPN.ps1` | Main application (~1,200 lines) |
| `config.json` | Settings (auto-created, gitignored) |
| `vpn_cred.dat` | Encrypted credentials (auto-created, gitignored) |

## How It Works

### Connection Flow

```
Step 1: Start SVPClient.exe
Step 2: Find Login window (or detect already connected)
Step 3: Click Login button (Win32 BM_CLICK)
Step 4: Handle Security Alert → click Yes
Step 5: Find User Authentication dialog
Step 6: Fill username/password → click OK (Win32 WM_SETTEXT)
Step 7: Verify connection via network adapter status
```

### Disconnect

SVPClient is protected by the NeoSrv system service and cannot be killed without admin rights. Disconnect triggers a **UAC prompt** to elevate and force-stop the process.

### Connection Detection

Uses `Get-NetAdapter` to check if `VMware SSL VPN-Plus Client Adapter` is **Up** - more reliable than window title detection (which is empty when connected).

## Configuration

Settings are stored in `config.json` (auto-created with defaults if missing):

| Setting | Default | Description |
|---------|---------|-------------|
| `vpn_client_path` | `C:\Program Files (x86)\VMware\SSL VPN-Plus Client\SVPClient.exe` | Path to VPN client |
| `connection_name` | `ADA-VPN` | VPN network name |
| `auto_connect` | `false` | Connect automatically on startup |
| `minimize_to_tray` | `true` | Minimize to system tray |
| `credential_file` | `vpn_cred.dat` | Encrypted credential file path |

To reset credentials: **Settings** > **Reset Credentials** > re-enter and **Save**.

## Security

- **DPAPI Encryption** - Credentials encrypted with Windows user key, cannot be decrypted by other accounts
- **Win32 Messages** - Direct control messaging instead of SendKeys (no keyboard/focus dependency)
- **Memory Cleanup** - Passwords cleared from memory after use
- **No Plaintext** - Credentials never stored or logged in plaintext

## Tech Stack

- PowerShell + Windows Forms (GUI)
- Win32 API / P/Invoke (VPN client automation)
- DPAPI (credential encryption)

## License

Private use only.
