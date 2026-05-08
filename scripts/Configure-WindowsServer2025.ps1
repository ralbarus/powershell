<#
.SYNOPSIS
    Interaktive Basiskonfiguration fuer Windows Server 2025.

.DESCRIPTION
    Das Skript zeigt ein Menue mit typischen Erstkonfigurationsoptionen an,
    fasst die Auswahl vor der Ausfuehrung zusammen, erlaubt Korrekturen und
    wendet die bestaetigten Optionen anschliessend an. Zum Abschluss kann der
    Anwender das Skript beenden oder den Server neu starten.

.NOTES
    Fuer Rolleninstallation, Netzwerkkonfiguration und Remotedesktop muss das
    Skript in einer erhoehten PowerShell-Sitzung ausgefuehrt werden.
#>

#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServerRoles = [ordered]@{
    ActiveDirectoryDomainServices = [pscustomobject]@{ Label = 'Active Directory Domaenendienste'; FeatureName = 'AD-Domain-Services' }
    DhcpServer                    = [pscustomobject]@{ Label = 'DHCP-Server'; FeatureName = 'DHCP' }
    DnsServer                     = [pscustomobject]@{ Label = 'DNS Server'; FeatureName = 'DNS' }
    RemoteDesktopServices         = [pscustomobject]@{ Label = 'Remote Desktop Services (RDS Session Host)'; FeatureName = 'RDS-RD-Server' }
    RemoteDesktopLicensing        = [pscustomobject]@{ Label = 'Remotedesktoplizenzierungsserver'; FeatureName = 'RDS-Licensing' }
    PrintServices                 = [pscustomobject]@{ Label = 'Druckserverdienste'; FeatureName = 'Print-Services' }
    FileServices                  = [pscustomobject]@{ Label = 'Dateidienste'; FeatureName = 'FS-FileServer' }
    HyperV                        = [pscustomobject]@{ Label = 'Hyper-V Server'; FeatureName = 'Hyper-V' }
    Iis                           = [pscustomobject]@{ Label = 'IIS (Internet Information Services)'; FeatureName = 'Web-Server' }
}

function New-ConfigurationState {
    [ordered]@{
        ServerName = $null
        IPv4 = [ordered]@{
            Enabled = $false
            InterfaceAlias = $null
            IPAddress = $null
            PrefixLength = $null
            DefaultGateway = $null
            DnsServers = @()
        }
        EnableRemoteDesktop = $false
        Roles = [ordered]@{}
        RegistryHacks = [ordered]@{
            EndTaskRightClick = $false
            PreventAccidentalDesktopIconMove = $false
        }
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Bitte starten Sie dieses Skript in einer erhoehten PowerShell-Sitzung (Als Administrator ausfuehren).'
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [bool]$Default = $false
    )

    $suffix = if ($Default) { '[J/n]' } else { '[j/N]' }

    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim()

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }

        switch -Regex ($answer) {
            '^(j|ja|y|yes)$' { return $true }
            '^(n|nein|no)$' { return $false }
            default { Write-Host 'Bitte J oder N eingeben.' -ForegroundColor Yellow }
        }
    }
}

function Read-RequiredValue {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [ScriptBlock]$Validator,

        [string]$ValidationMessage = 'Ungueltige Eingabe.'
    )

    while ($true) {
        $value = (Read-Host $Prompt).Trim()

        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host 'Die Eingabe darf nicht leer sein.' -ForegroundColor Yellow
            continue
        }

        if ($Validator -and -not (& $Validator $value)) {
            Write-Host $ValidationMessage -ForegroundColor Yellow
            continue
        }

        return $value
    }
}

function Test-IPv4Address {
    param([string]$Value)

    [System.Net.IPAddress]$address = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$address) -and $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-PrefixLength {
    param([string]$Value)

    $prefix = 0
    return [int]::TryParse($Value, [ref]$prefix) -and $prefix -ge 1 -and $prefix -le 32
}

function Select-IPv4Configuration {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    $Config.IPv4.Enabled = Read-YesNo -Prompt 'IPv4-Adresse manuell vergeben?' -Default ([bool]$Config.IPv4.Enabled)

    if (-not $Config.IPv4.Enabled) {
        $Config.IPv4.InterfaceAlias = $null
        $Config.IPv4.IPAddress = $null
        $Config.IPv4.PrefixLength = $null
        $Config.IPv4.DefaultGateway = $null
        $Config.IPv4.DnsServers = @()
        return
    }

    Write-Host ''
    Write-Host 'Vorhandene Netzwerkadapter:' -ForegroundColor Cyan
    Get-NetAdapter | Sort-Object -Property Name | Format-Table -AutoSize -Property Name, Status, LinkSpeed, MacAddress

    $Config.IPv4.InterfaceAlias = Read-RequiredValue -Prompt 'InterfaceAlias/Adaptername'
    $Config.IPv4.IPAddress = Read-RequiredValue -Prompt 'IPv4-Adresse' -Validator ${function:Test-IPv4Address} -ValidationMessage 'Bitte eine gueltige IPv4-Adresse eingeben.'
    $Config.IPv4.PrefixLength = [int](Read-RequiredValue -Prompt 'Praefixlaenge (z. B. 24)' -Validator ${function:Test-PrefixLength} -ValidationMessage 'Bitte eine Zahl zwischen 1 und 32 eingeben.')
    $Config.IPv4.DefaultGateway = Read-RequiredValue -Prompt 'Standardgateway' -Validator ${function:Test-IPv4Address} -ValidationMessage 'Bitte eine gueltige IPv4-Adresse eingeben.'

    while ($true) {
        $dnsInput = (Read-Host 'DNS-Server durch Komma getrennt (z. B. 192.168.1.10,192.168.1.11)').Trim()
        $dnsServers = @($dnsInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        if ($dnsServers.Count -gt 0 -and ($dnsServers | Where-Object { -not (Test-IPv4Address $_) }).Count -eq 0) {
            $Config.IPv4.DnsServers = $dnsServers
            break
        }

        Write-Host 'Bitte mindestens einen gueltigen IPv4-DNS-Server eingeben.' -ForegroundColor Yellow
    }
}

function Select-ServerRoles {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    foreach ($key in $ServerRoles.Keys) {
        if (-not $Config.Roles.Contains($key)) {
            $Config.Roles[$key] = $false
        }
    }

    Write-Host ''
    Write-Host 'Serverrollen auswaehlen:' -ForegroundColor Cyan

    foreach ($key in $ServerRoles.Keys) {
        $current = [bool]$Config.Roles[$key]
        $Config.Roles[$key] = Read-YesNo -Prompt $ServerRoles[$key].Label -Default $current
    }
}

function Select-RegistryHacks {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    Write-Host ''
    Write-Host 'Registry Hacks auswaehlen:' -ForegroundColor Cyan
    $Config.RegistryHacks.EndTaskRightClick = Read-YesNo -Prompt 'Task beenden per Rechtsklick aktivieren (WinUtil-Variante)?' -Default ([bool]$Config.RegistryHacks.EndTaskRightClick)
    $Config.RegistryHacks.PreventAccidentalDesktopIconMove = Read-YesNo -Prompt 'Versehentliches Verschieben von Desktopsymbolen erschweren (DragHeight/DragWidth)?' -Default ([bool]$Config.RegistryHacks.PreventAccidentalDesktopIconMove)
}

function Invoke-ConfigurationSelection {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    Clear-Host
    Write-Host 'Windows Server 2025 - automatische Konfiguration' -ForegroundColor Cyan
    Write-Host '================================================'

    if (Read-YesNo -Prompt 'Servernamen definieren?' -Default (-not [string]::IsNullOrWhiteSpace($Config.ServerName))) {
        $Config.ServerName = Read-RequiredValue -Prompt 'Neuer Servername' -Validator { param($value) $value -match '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' } -ValidationMessage 'Max. 15 Zeichen, nur Buchstaben, Zahlen und Bindestriche; darf nicht mit Bindestrich beginnen.'
    }
    else {
        $Config.ServerName = $null
    }

    Select-IPv4Configuration -Config $Config
    $Config.EnableRemoteDesktop = Read-YesNo -Prompt 'Remotedesktopverbindungen aktivieren?' -Default ([bool]$Config.EnableRemoteDesktop)
    Select-ServerRoles -Config $Config
    Select-RegistryHacks -Config $Config
}

function Get-SelectedRoleLabels {
    param([System.Collections.IDictionary]$Config)

    $selected = foreach ($key in $ServerRoles.Keys) {
        if ($Config.Roles.Contains($key) -and $Config.Roles[$key]) {
            $ServerRoles[$key].Label
        }
    }

    @($selected)
}

function Show-ConfigurationSummary {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    Clear-Host
    Write-Host 'Ausgewaehlte Optionen' -ForegroundColor Cyan
    Write-Host '====================='
    Write-Host ("Servername: {0}" -f $(if ($Config.ServerName) { $Config.ServerName } else { 'Keine Aenderung' }))

    if ($Config.IPv4.Enabled) {
        Write-Host 'IPv4: Manuell'
        Write-Host ("  Adapter:        {0}" -f $Config.IPv4.InterfaceAlias)
        Write-Host ("  IP-Adresse:     {0}/{1}" -f $Config.IPv4.IPAddress, $Config.IPv4.PrefixLength)
        Write-Host ("  Gateway:        {0}" -f $Config.IPv4.DefaultGateway)
        Write-Host ("  DNS-Server:     {0}" -f ($Config.IPv4.DnsServers -join ', '))
    }
    else {
        Write-Host 'IPv4: Keine Aenderung'
    }

    Write-Host ("Remotedesktop: {0}" -f $(if ($Config.EnableRemoteDesktop) { 'Aktivieren' } else { 'Keine Aenderung' }))

    $roles = Get-SelectedRoleLabels -Config $Config
    if ($roles.Count -gt 0) {
        Write-Host 'Serverrollen:'
        $roles | ForEach-Object { Write-Host "  - $_" }
    }
    else {
        Write-Host 'Serverrollen: Keine Auswahl'
    }

    $registrySelections = @()
    if ($Config.RegistryHacks.EndTaskRightClick) { $registrySelections += 'Task beenden per Rechtsklick' }
    if ($Config.RegistryHacks.PreventAccidentalDesktopIconMove) { $registrySelections += 'Versehentliches Verschieben von Desktopsymbolen erschweren' }

    if ($registrySelections.Count -gt 0) {
        Write-Host 'Registry Hacks:'
        $registrySelections | ForEach-Object { Write-Host "  - $_" }
    }
    else {
        Write-Host 'Registry Hacks: Keine Auswahl'
    }

    Write-Host ''
}

function Confirm-Configuration {
    while ($true) {
        $answer = (Read-Host 'Auswahl anwenden? [A]nwenden / [Z]urueck / [B]eenden').Trim()
        switch -Regex ($answer) {
            '^(a|anwenden)$' { return 'Apply' }
            '^(z|zurueck|zurück)$' { return 'Back' }
            '^(b|beenden)$' { return 'Exit' }
            default { Write-Host 'Bitte A, Z oder B eingeben.' -ForegroundColor Yellow }
        }
    }
}

function Set-ManualIPv4Configuration {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$IPv4
    )

    Write-Host 'Konfiguriere IPv4-Adresse ...' -ForegroundColor Cyan

    $adapter = Get-NetAdapter -Name $IPv4.InterfaceAlias -ErrorAction Stop
    Set-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4 -Dhcp Disabled

    Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne $IPv4.IPAddress -and $_.PrefixOrigin -ne 'WellKnown' } |
        Remove-NetIPAddress -Confirm:$false

    Get-NetRoute -InterfaceAlias $adapter.Name -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false

    $existingAddress = Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -IPAddress $IPv4.IPAddress -ErrorAction SilentlyContinue
    if (-not $existingAddress) {
        New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $IPv4.IPAddress -PrefixLength $IPv4.PrefixLength -DefaultGateway $IPv4.DefaultGateway | Out-Null
    }

    Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses $IPv4.DnsServers
}

function Enable-RemoteDesktopConnections {
    Write-Host 'Aktiviere Remotedesktopverbindungen ...' -ForegroundColor Cyan
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' | Out-Null
}

function Install-SelectedServerRoles {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    $features = foreach ($key in $ServerRoles.Keys) {
        if ($Config.Roles.Contains($key) -and $Config.Roles[$key]) {
            $ServerRoles[$key].FeatureName
        }
    }

    $features = @($features | Select-Object -Unique)
    if ($features.Count -eq 0) {
        return
    }

    Write-Host ("Installiere Serverrollen: {0}" -f ($features -join ', ')) -ForegroundColor Cyan
    Install-WindowsFeature -Name $features -IncludeManagementTools | Format-Table -AutoSize
}

function Set-RegistryHacks {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    if ($Config.RegistryHacks.EndTaskRightClick) {
        Write-Host 'Aktiviere "Task beenden" per Rechtsklick ...' -ForegroundColor Cyan
        $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'
        New-Item -Path $path -Force | Out-Null
        New-ItemProperty -Path $path -Name 'TaskbarEndTask' -PropertyType DWord -Value 1 -Force | Out-Null
    }

    if ($Config.RegistryHacks.PreventAccidentalDesktopIconMove) {
        Write-Host 'Setze DragHeight/DragWidth gegen versehentliches Verschieben ...' -ForegroundColor Cyan
        $path = 'HKCU:\Control Panel\Desktop'
        New-ItemProperty -Path $path -Name 'DragHeight' -PropertyType String -Value '50' -Force | Out-Null
        New-ItemProperty -Path $path -Name 'DragWidth' -PropertyType String -Value '50' -Force | Out-Null
    }
}

function Invoke-ConfigurationApply {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    Assert-Administrator

    if ($Config.ServerName) {
        $currentName = $env:COMPUTERNAME
        if ($currentName -ne $Config.ServerName) {
            Write-Host ("Benenne Server von {0} in {1} um ..." -f $currentName, $Config.ServerName) -ForegroundColor Cyan
            Rename-Computer -NewName $Config.ServerName -Force
        }
        else {
            Write-Host 'Servername ist bereits gesetzt.' -ForegroundColor Green
        }
    }

    if ($Config.IPv4.Enabled) {
        Set-ManualIPv4Configuration -IPv4 $Config.IPv4
    }

    if ($Config.EnableRemoteDesktop) {
        Enable-RemoteDesktopConnections
    }

    Install-SelectedServerRoles -Config $Config
    Set-RegistryHacks -Config $Config
}

function Invoke-ExitOrRestartPrompt {
    while ($true) {
        $answer = (Read-Host 'Abschluss: [B]eenden oder [N]eu starten?').Trim()
        switch -Regex ($answer) {
            '^(b|beenden)$' { return }
            '^(n|neu|neustart|restart)$' {
                Write-Host 'Server wird neu gestartet ...' -ForegroundColor Cyan
                Restart-Computer -Force
                return
            }
            default { Write-Host 'Bitte B oder N eingeben.' -ForegroundColor Yellow }
        }
    }
}

$configuration = New-ConfigurationState
$applyConfirmed = $false

while (-not $applyConfirmed) {
    Invoke-ConfigurationSelection -Config $configuration
    Show-ConfigurationSummary -Config $configuration
    $decision = Confirm-Configuration

    switch ($decision) {
        'Apply' { $applyConfirmed = $true }
        'Back' { continue }
        'Exit' { Write-Host 'Skript wurde ohne Aenderungen beendet.' -ForegroundColor Yellow; return }
    }
}

try {
    Invoke-ConfigurationApply -Config $configuration
    Write-Host ''
    Write-Host 'Konfiguration abgeschlossen. Einige Aenderungen werden erst nach einem Neustart wirksam.' -ForegroundColor Green
    Invoke-ExitOrRestartPrompt
}
catch {
    Write-Error $_
    exit 1
}
