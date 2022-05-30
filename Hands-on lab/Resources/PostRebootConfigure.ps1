Function Set-VMNetworkConfiguration {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='DHCP',
                   ValueFromPipeline=$true)]
        [Parameter(Mandatory=$true,
                   Position=0,
                   ParameterSetName='Static',
                   ValueFromPipeline=$true)]
        [Microsoft.HyperV.PowerShell.VMNetworkAdapter]$NetworkAdapter,

        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='Static')]
        [String[]]$IPAddress=@(),

        [Parameter(Mandatory=$false,
                   Position=2,
                   ParameterSetName='Static')]
        [String[]]$Subnet=@(),

        [Parameter(Mandatory=$false,
                   Position=3,
                   ParameterSetName='Static')]
        [String[]]$DefaultGateway = @(),

        [Parameter(Mandatory=$false,
                   Position=4,
                   ParameterSetName='Static')]
        [String[]]$DNSServer = @(),

        [Parameter(Mandatory=$false,
                   Position=0,
                   ParameterSetName='DHCP')]
        [Switch]$Dhcp
    )

    $VM = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_ComputerSystem' | Where-Object { $_.ElementName -eq $NetworkAdapter.VMName } 
    $VMSettings = $vm.GetRelated('Msvm_VirtualSystemSettingData') | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }    
    $VMNetAdapters = $VMSettings.GetRelated('Msvm_SyntheticEthernetPortSettingData') 

    $NetworkSettings = @()
    foreach ($NetAdapter in $VMNetAdapters) {
        if ($NetAdapter.Address -eq $NetworkAdapter.MacAddress) {
            $NetworkSettings = $NetworkSettings + $NetAdapter.GetRelated("Msvm_GuestNetworkAdapterConfiguration")
        }
    }

    $NetworkSettings[0].IPAddresses = $IPAddress
    $NetworkSettings[0].Subnets = $Subnet
    $NetworkSettings[0].DefaultGateways = $DefaultGateway
    $NetworkSettings[0].DNSServers = $DNSServer
    $NetworkSettings[0].ProtocolIFType = 4096

    if ($dhcp) {
        $NetworkSettings[0].DHCPEnabled = $true
    } else {
        $NetworkSettings[0].DHCPEnabled = $false
    }

    $Service = Get-WmiObject -Class "Msvm_VirtualSystemManagementService" -Namespace "root\virtualization\v2"
    $setIP = $Service.SetGuestNetworkAdapterConfiguration($VM, $NetworkSettings[0].GetText(1))

    if ($setip.ReturnValue -eq 4096) {
        $job=[WMI]$setip.job 

        while ($job.JobState -eq 3 -or $job.JobState -eq 4) {
            start-sleep 1
            $job=[WMI]$setip.job
        }

        if ($job.JobState -eq 7) {
            write-host "Success"
        }
        else {
            $job.GetError()
        }
    } elseif($setip.ReturnValue -eq 0) {
        Write-Host "Success"
    }
}

Function Expand-Files {
    Param (
        [Object]$Files,
        [string]$Destination
    )

    foreach ($file in $files)
    {
        $fileName = $file.FullName

        write-output "Start unzip: $fileName to $Destination"
        
        $7zEXE = "$opsDir\7z\7za.exe"

        cmd /c "$7zEXE x -y -o$Destination $fileName" | Add-Content $cmdLogPath
        
        write-output "Finish unzip: $fileName to $Destination"
    }
}

Function Follow-Redirect {
    Param (
        [string]$Url
    )

    $webClientObject = New-Object System.Net.WebClient
    $webRequest = [System.Net.WebRequest]::create($Url)
    $webResponse = $webRequest.GetResponse()
    $actualUrl = $webResponse.ResponseUri.AbsoluteUri
    $webResponse.Close()

    return $actualUrl
}

Function Wait-For-Website {
    Param (
        [string]$Url
    )

    $i = 1
    while ($true) {

        try {
            Write-Output "Checking ($i)...please wait"
            $i++

            $response = Invoke-WebRequest -Uri $Url -TimeoutSec 10 -UseBasicParsing
            if ($response.StatusCode -eq 200) {
                return;
            }
        } catch {}

        Start-Sleep 2
    }
}

Function Rearm-VM {
    Param (
        [string]$ComputerName,
        [string]$Username,
        [string]$Password
    )

    Write-Output "Getting IP for $ComputerName"

    $vm = Get-VM -Name $ComputerName
    # Wait for VM to become available and on the network before proceeding to re-arm licenses
    do {
        if ($vm.state -eq "Off")  {
            Write-Output "Attempting to start $ComputerName..."
            $vm | Start-VM
        }
        sleep -Seconds 5
        $ip = $vm.NetworkAdapters[0].IpAddresses[0]
    } until ($ip)

    Write-Output "Creating credentials object"
    $localusername = "$computerName\$Username"
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $localcredential = New-Object System.Management.Automation.PSCredential ($localusername, $securePassword)

    Write-Output "Re-arm (extend eval license) for VM $ComputerName at $ip"
    set-item wsman:\localhost\Client\TrustedHosts -value $ip -Force

    Invoke-Command -ComputerName $ip -ScriptBlock { 
        slmgr.vbs /rearm
        net accounts /maxpwage:unlimited
        Restart-Computer -Force 
    } -Credential $localcredential

    Write-Output "Re-arm complete"
}

Start-Transcript -Path "C:\PostRebootConfigure_log.txt"
$cmdLogPath = "C:\PostRebootConfigure_log_cmd.txt"

Start-Sleep 60
$ErrorActionPreference = 'continue'
Import-Module BitsTransfer

# Create paths
Write-Output "Create paths"
$opsDir = "C:\OpsgilityTraining"
$vmDir = "F:\VirtualMachines"
$tempDir = "D:\"
New-Item -Path $vmDir -ItemType directory -Force

# Unregister scheduled task so this script doesn't run again on next reboot
Write-Output "Remove PostRebootConfigure scheduled task"
Unregister-ScheduledTask -TaskName "SetUpVMs" -Confirm:$false

# Download AzCopy. We won't use the aka.ms/downloadazcopy link in case of breaking changes in later versions
Write-Output "Download and install AzCopy"
$azcopyUrl = "https://cloudworkshop.blob.core.windows.net/line-of-business-application-migration/sept-2020/azcopy_windows_amd64_10.1.1.zip"
$azcopyZip = "$opsDir\azcopy.zip"
Start-BitsTransfer -Source $azcopyUrl -Destination $azcopyZip
$azcopyZipfile = Get-ChildItem -Path $azcopyZip
Expand-Files -Files $azcopyZipfile -Destination $opsDir
$azcopy = "$opsDir\azcopy_windows_amd64_10.1.1\azcopy.exe"

# Download SmartHotel VMs from blob storage
# Also download Azure Migrate appliance (saves time in lab later)
Write-Output "Download nested VM zip files using AzCopy"
$sourceFolder = 'https://cloudworkshop.blob.core.windows.net/line-of-business-application-migration/sept-2020'

cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $sourceFolder/SmartHotelWeb1.zip $tempDir\SmartHotelWeb1.zip" | Add-Content $cmdLogPath
cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $sourceFolder/SmartHotelWeb2.zip $tempDir\SmartHotelWeb2.zip" | Add-Content $cmdLogPath
cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $sourceFolder/SmartHotelSQL1.zip $tempDir\SmartHotelSQL1.zip" | Add-Content $cmdLogPath
cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $sourceFolder/UbuntuWAF.zip $tempDir\UbuntuWAF.zip" | Add-Content $cmdLogPath
cmd /c "$azcopy cp --check-md5 FailIfDifferentOrMissing $sourceFolder/AzureMigrateAppliance_v25.22.04.11.zip $tempDir\AzureMigrate.zip" | Add-Content $cmdLogPath

# Unzip the VMs
Write-Output "Unzip nested VMs"
$zipfiles = Get-ChildItem -Path "$tempDir\*.zip"
Expand-Files -Files $zipfiles -Destination $vmDir

# Create the NAT network
Write-Output "Create internal NAT"
$natName = "InternalNat"
New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 192.168.0.0/16

# Create an internal switch with NAT
Write-Output "Create internal switch"
$switchName = 'InternalNATSwitch'
New-VMSwitch -Name $switchName -SwitchType Internal
$adapter = Get-NetAdapter | Where-Object { $_.Name -like "*"+$switchName+"*" }

# Create an internal network (gateway first)
Write-Output "Create gateway"
New-NetIPAddress -IPAddress 192.168.0.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex

# Enable Enhanced Session Mode on Host
Write-Output "Enable Enhanced Session Mode"
Set-VMHost -EnableEnhancedSessionMode $true

# Create the nested Windows VMs - from VHDs
Write-Output "Create Hyper-V VMs"
New-VM -Name smarthotelweb1 -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$vmdir\SmartHotelWeb1\SmartHotelWeb1.vhdx" -Path "$vmdir\SmartHotelWeb1" -Generation 2 -Switch $switchName 
New-VM -Name smarthotelweb2 -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$vmdir\SmartHotelWeb2\SmartHotelWeb2.vhdx" -Path "$vmdir\SmartHotelWeb2" -Generation 2 -Switch $switchName
New-VM -Name smarthotelSQL1 -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$vmdir\SmartHotelSQL1\SmartHotelSQL1.vhdx" -Path "$vmdir\SmartHotelSQL1" -Generation 2 -Switch $switchName
New-VM -Name UbuntuWAF      -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$vmdir\UbuntuWAF\UbuntuWAF.vhdx"           -Path "$vmdir\UbuntuWAF"      -Generation 1 -Switch $switchName

# Configure IP addresses (don't change the IPs! VM config depends on them)
Write-Output "Configure VM networking"
Get-VMNetworkAdapter -VMName "smarthotelweb1" | Set-VMNetworkConfiguration -IPAddress "192.168.0.4" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"
Get-VMNetworkAdapter -VMName "smarthotelweb2" | Set-VMNetworkConfiguration -IPAddress "192.168.0.5" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"
Get-VMNetworkAdapter -VMName "smarthotelsql1" | Set-VMNetworkConfiguration -IPAddress "192.168.0.6" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"
Get-VMNetworkAdapter -VMName "UbuntuWAF"      | Set-VMNetworkConfiguration -IPAddress "192.168.0.8" -Subnet "255.255.255.0" -DefaultGateway "192.168.0.1" -DNSServer "8.8.8.8"

# We always want the VMs to start with the host and shut down cleanly with the host
# (If they just save state, which is the default, they can break if the host re-starts on a different CPU architecture)
Write-Output "Set VM auto start/stop"
Get-VM | Set-VM -AutomaticStartAction Start -AutomaticStopAction ShutDown

# Start all the VMs
Write-Output "Start VMs"
Get-VM | Start-VM

# Ping website to warm it up
Write-Output "Wait for smarthotel site"
Wait-For-Website('http://192.168.0.8')

# Rearm (extend evaluation license) and reboot each Windows VM
Write-Output "Re-arming Windows VMs (extend eval licenses)"
Rearm-VM -ComputerName "smarthotelweb1" -Username "Administrator" -Password "demo!pass123"
Rearm-VM -ComputerName "smarthotelweb2" -Username "Administrator" -Password "demo!pass123"
Rearm-VM -ComputerName "smarthotelSQL1" -Username "Administrator" -Password "demo!pass123"

# Warm up the app after the re-arm reboots
Write-Output "Waiting for SmartHotel reboot"
Wait-For-Website('http://192.168.0.8')

# Add NAT forwarders
# We do this and the firewall rules last so the user check that the web site is working when accessed via the host IP only works once all the other set-up is completed
Write-Output "Create NAT rules"
Add-NetNatStaticMapping -ExternalIPAddress "0.0.0.0" -ExternalPort 80   -Protocol TCP -InternalIPAddress "192.168.0.8" -InternalPort 80   -NatName $natName
Add-NetNatStaticMapping -ExternalIPAddress "0.0.0.0" -ExternalPort 1433 -Protocol TCP -InternalIPAddress "192.168.0.6" -InternalPort 1433 -NatName $natName

# Add a firewall rule for HTTP and SQL
Write-Output "Create firewall rules"
New-NetFirewallRule -DisplayName "HTTP Inbound" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Microsoft SQL Server Inbound" -Direction Inbound -LocalPort 1433 -Protocol TCP -Action Allow

# Set up separate subnet for Azure Migrate Appliance
Write-Output "Create AzureMigrateSwitch"
New-VMSwitch -Name AzureMigrateSwitch -SwitchType Internal
$adapter = Get-NetAdapter | ? { $_.Name -like "*Migrat*" }
Write-Output "Create gateway"
New-NetIPAddress -IPAddress 192.168.1.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex

Stop-Transcript
