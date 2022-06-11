Start-Transcript "C:\BootstrapSmartHotelHost_log.txt"

$ErrorActionPreference = 'SilentlyContinue'

# Disable IE ESC
Write-Output "Disable IE Enhanced Security Configuration"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" -Name "IsInstalled" -Value 0
Stop-Process -Name Explorer

# Install Chrome
Write-Output "Install Chrome"
$Path = $env:TEMP; 
$Installer = "chrome_installer.exe"
Invoke-WebRequest "http://dl.google.com/chrome/install/375.126/chrome_installer.exe" -OutFile $Path\$Installer
Start-Process -FilePath $Path\$Installer -Args "/silent /install" -Verb RunAs -Wait
Remove-Item $Path\$Installer

# Create command prompt desktop shortcut
New-Item -ItemType SymbolicLink -Path "C:\Users\All Users\Desktop" -Name "Command Prompt" -Value "$env:windir\System32\cmd.exe"

# Create path
Write-Output "Create paths"
$opsDir = "C:\OpsgilityTraining"
New-Item -Path $opsDir -ItemType directory -Force

# Format data disk
Write-Output "Format data disk"
$disk = Get-Disk | ? { $_.PartitionStyle -eq "RAW" }
Initialize-Disk -Number $disk.DiskNumber -PartitionStyle GPT
New-Partition -DiskNumber $disk.DiskNumber -UseMaximumSize -DriveLetter F
Format-Volume -DriveLetter F -FileSystem NTFS -NewFileSystemLabel DATA

# path for 7z
$7zDir = "$opsDir\7z"
New-Item -Path $7zDir -ItemType directory -Force

# Download post-migration script and 7z
Write-Output "Download with Bits"
$sourceFolder = 'https://openhackpublic.blob.core.windows.net/lob-migration/sept-2021'
$downloads = @( `
     "$sourceFolder/PostRebootConfigure.ps1" `
    ,"$sourceFolder/7z/7za.exe" `
    ,"$sourceFolder/7z/7za.dll" `
    ,"$sourceFolder/7z/7zxa.dll" `
    )

$destinationFiles = @( `
     "$opsDir\PostRebootConfigure.ps1" `
    ,"$7zDir\7za.exe" `
    ,"$7zDir\7za.dll" `
    ,"$7zDir\7zxa.dll" `
    )

Import-Module BitsTransfer
Start-BitsTransfer -Source $downloads -Destination $destinationFiles

# Register task to run post-reboot script once host is rebooted after Hyper-V install
Write-Output "Register post-reboot script as scheduled task"
$action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe" -Argument "-executionPolicy Unrestricted -File $opsDir\PostRebootConfigure.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "SetUpVMs" -Action $action -Trigger $trigger -Principal $principal

# Install and configure DHCP service (used by Azure Migrate appliance so DNS lookup of 'SmartHotelHost' works)
Write-Output "Install and configure DHCP service"
$dnsClient = Get-DnsClient | Where-Object {$_.InterfaceAlias -eq "Ethernet" }
Install-WindowsFeature -Name "DHCP" -IncludeManagementTools
Add-DhcpServerv4Scope -Name "Migrate" -StartRange 192.168.1.1 -EndRange 192.168.1.254 -SubnetMask 255.255.255.0 -State Active
Add-DhcpServerv4ExclusionRange -ScopeID 192.168.1.0 -StartRange 192.168.1.1 -EndRange 192.168.1.15
Set-DhcpServerv4OptionValue -DnsDomain $dnsClient.ConnectionSpecificSuffix -DnsServer 168.63.129.16
Set-DhcpServerv4OptionValue -OptionID 3 -Value 192.168.1.1 -ScopeID 192.168.1.0
Set-DhcpServerv4Scope -ScopeId 192.168.1.0 -LeaseDuration 1.00:00:00
Restart-Service dhcpserver

# Install Windows Subsystem for Linux
# Used for Bash shell to SSH to the UbuntuWAF
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart

# Install Hyper-V and reboot
Write-Output "Install Hyper-V and restart"
Stop-Transcript
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart