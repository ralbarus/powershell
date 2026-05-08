# powershell

Powershell Scripts for Admins (Active Directory, Files, Printers)

## Scripts

### `scripts/Configure-WindowsServer2025.ps1`

Interactive PowerShell script for the initial configuration of Windows Server 2025. The script lets an administrator choose the desired options, review the selection, return to the selection screen for changes, apply the confirmed configuration, and finally exit or restart the server.

Included options:

- Define the server name
- Configure a manual IPv4 address
- Enable Remote Desktop connections
- Install common server roles such as AD DS, DHCP, DNS, RDS, print services, file services, Hyper-V, and IIS
- Apply registry tweaks for the current user:
  - Enable **End task** in the taskbar right-click menu
  - Increase `DragHeight` and `DragWidth` to reduce accidental icon/file moves

Run it from an elevated PowerShell session:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\scripts\Configure-WindowsServer2025.ps1
```
