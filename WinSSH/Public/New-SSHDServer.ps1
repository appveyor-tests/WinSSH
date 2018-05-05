function New-SSHDServer {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$False)]
        [switch]$RemoveHostPrivateKeys,

        [Parameter(Mandatory=$False)]
        [ValidateSet("powershell","pwsh")]
        [string]$DefaultShell,

        [Parameter(Mandatory=$False)]
        [switch]$SkipWinCapabilityAttempt
    )

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####

    if (!$(GetElevation)) {
        Write-Verbose "You must run PowerShell as Administrator before using this function! Halting!"
        Write-Error "You must run PowerShell as Administrator before using this function! Halting!"
        $global:FunctionResult = "1"
        return
    }

    # Make sure the dependency ssh-agent service is already installed
    if (![bool]$(Get-Service ssh-agent -ErrorAction SilentlyContinue)) {
        try {
            $InstallSSHAgentSplatParams = @{
                ErrorAction         = "SilentlyContinue"
                ErrorVariable       = "ISAErr"
            }
            if ($SkipWinCapabilityAttempt) {
                $InstallSSHAgentSplatParams.Add("SkipWinCapabilityAttempt",$True)
            }
            if ($Force) {
                $InstallSSHAgentSplatParams.Add("Force",$True)
            }
            
            $InstallSSHAgentResult = Install-SSHAgentService @InstallSSHAgentSplatParams
            if (!$InstallSSHAgentResult) {throw "The Install-SSHAgentService function failed!"}
        }
        catch {
            Write-Error $_
            Write-Host "Errors for the Install-SSHAgentService function are as follows:"
            Write-Error $($ISAErr | Out-String)
            $global:FunctionResult = "1"
            return
        }
    }

    if ([Environment]::OSVersion.Version -ge [version]"10.0.17063" -and !$SkipWinCapabilityAttempt) {
        try {
            # Import the Dism Module
            if ($(Get-Module).Name -notcontains "Dism") {
                try {
                    Import-Module Dism
                }
                catch {
                    # Using full path to Dism Module Manifest because sometimes there are issues with just 'Import-Module Dism'
                    $DismModuleManifestPaths = $(Get-Module -ListAvailable -Name Dism).Path

                    foreach ($MMPath in $DismModuleManifestPaths) {
                        try {
                            Import-Module $MMPath -ErrorAction Stop
                            break
                        }
                        catch {
                            Write-Verbose "Unable to import $MMPath..."
                        }
                    }
                }
            }
            if ($(Get-Module).Name -notcontains "Dism") {
                Write-Error "Problem importing the Dism PowerShell Module! Unable to proceed with Hyper-V install! Halting!"
                $global:FunctionResult = "1"
                return
            }

            $SSHDServerFeature = Get-WindowsCapability -Online | Where-Object {$_.Name -match 'OpenSSH\.Server'}

            if (!$SSHDServerFeature) {
                Write-Warning "Unable to find the OpenSSH.Server feature using the Get-WindowsCapability cmdlet!"
                $AddWindowsCapabilityFailure = $True
            }
            else {
                try {
                    $SSHDFeatureInstall = Add-WindowsCapability -Online -Name $SSHDServerFeature.Name -ErrorAction Stop
                }
                catch {
                    Write-Warning "The Add-WindowsCapability cmdlet failed to add the $($SSHDServerFeature.Name)!"
                    $AddWindowsCapabilityFailure = $True
                }
            }

            # Make sure the sshd service exists
            try {
                $SSHDServiceCheck = Get-Service sshd -ErrorAction Stop
            }
            catch {
                $AddWindowsCapabilityFailure = $True
            }
        }
        catch {
            Write-Warning "The Add-WindowsCapability cmdlet failed to add feature: $($SSHDServerFeature.Name) !"
            $AddWindowsCapabilityFailure = $True
        }
        
        if (!$AddWindowsCapabilityFailure) {
            $OpenSSHWinPath = "$env:ProgramFiles\OpenSSH-Win64"
            $sshdpath = Join-Path $OpenSSHWinPath "sshd.exe"
            $sshdir = "$env:ProgramData\ssh"
            $logsdir = Join-Path $sshdir "logs"
            $sshdConfigPath = Join-Path $sshdir "sshd_config"

            try {
                # NOTE: $sshdir won't actually be created until you start the SSHD Service for the first time
                # Starting the service also creates all of the needed host keys.
                $SSHDServiceInfo = Get-Service sshd -ErrorAction Stop
                if ($SSHDServiceInfo.Status -ne "Running") {
                    $SSHDServiceInfo | Start-Service -ErrorAction Stop
                }

                if (Test-Path "$env:ProgramFiles\OpenSSH-Win64\sshd_config_default") {
                    # Copy sshd_config_default to $sshdir\sshd_config
                    $sshddefaultconfigpath = Join-Path $OpenSSHWinPath "sshd_config_default"
                    if (-not (Test-Path $sshdconfigpath -PathType Leaf)) {
                        $null = Copy-Item $sshddefaultconfigpath -Destination $sshdconfigpath -Force -ErrorAction Stop
                    }
                }
                else {
                    $SSHConfigUri = "https://raw.githubusercontent.com/PowerShell/Win32-OpenSSH/L1-Prod/contrib/win32/openssh/sshd_config"
                    Invoke-WebRequest -Uri $SSHConfigUri -OutFile $sshdConfigPath
                }

                $PubPrivKeyPairFiles = Get-ChildItem -Path $sshdir | Where-Object {$_.CreationTime -gt (Get-Date).AddSeconds(-5) -and $_.Name -match "ssh_host"}
                $PubKeys = $PubPrivKeyPairFiles | Where-Object {$_.Extension -eq ".pub"}
                $PrivKeys = $PubPrivKeyPairFiles | Where-Object {$_.Extension -ne ".pub"}
            }
            catch {
                Write-Error $_
                $global:FunctionResult = "1"
                return
            }
        }
    }
    
    if ([Environment]::OSVersion.Version -lt [version]"10.0.17063" -or $AddWindowsCapabilityFailure -or $SkipWinCapabilityAttempt) {
        $OpenSSHWinPath = "$env:ProgramFiles\OpenSSH-Win64"
        if (!$(Test-Path $OpenSSHWinPath)) {
            try {
                $InstallSSHAgentResult = Install-SSHAgentService -ErrorAction SilentlyContinue -ErrorVariable ISAErr
                if (!$InstallSSHAgentResult) {throw "The Install-SSHAgentService function failed!"}
            }
            catch {
                Write-Error $_
                Write-Host "Errors for the Install-SSHAgentService function are as follows:"
                Write-Error $($ISAErr | Out-String)
                $global:FunctionResult = "1"
                return
            }
        }

        if (!$(Test-Path $OpenSSHWinPath)) {
            Write-Error "The path $OpenSSHWinPath does not exist! Halting!"
            $global:FunctionResult = "1"
            return
        }
        $sshdpath = Join-Path $OpenSSHWinPath "sshd.exe"
        if (!$(Test-Path $sshdpath)) {
            Write-Error "The path $sshdpath does not exist! Halting!"
            $global:FunctionResult = "1"
            return
        }
        $sshagentpath = Join-Path $OpenSSHWinPath "ssh-agent.exe"
        $sshdir = "$env:ProgramData\ssh"
        $logsdir = Join-Path $sshdir "logs"

        try {
            # Create the C:\ProgramData\ssh folder and set its permissions
            if (-not (Test-Path $sshdir -PathType Container)) {
                $null = New-Item $sshdir -ItemType Directory -Force -ErrorAction Stop
            }
            # Set Permissions
            $SecurityDescriptor = Get-NTFSSecurityDescriptor -Path $sshdir
            $SecurityDescriptor | Disable-NTFSAccessInheritance -RemoveInheritedAccessRules
            $SecurityDescriptor | Clear-NTFSAccess
            $SecurityDescriptor | Add-NTFSAccess -Account "NT AUTHORITY\Authenticated Users" -AccessRights "ReadAndExecute, Synchronize" -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Add-NTFSAccess -Account SYSTEM -AccessRights FullControl -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Add-NTFSAccess -Account Administrators -AccessRights FullControl -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Set-NTFSSecurityDescriptor
            Set-NTFSOwner -Path $sshdir -Account Administrators
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            return
        }

        try {
            # Create logs folder and set its permissions
            if (-not (Test-Path $logsdir -PathType Container)) {
                $null = New-Item $logsdir -ItemType Directory -Force -ErrorAction Stop
            }
            # Set Permissions
            $SecurityDescriptor = Get-NTFSSecurityDescriptor -Path $logsdir
            $SecurityDescriptor | Disable-NTFSAccessInheritance -RemoveInheritedAccessRules
            $SecurityDescriptor | Clear-NTFSAccess
            #$SecurityDescriptor | Add-NTFSAccess -Account "NT AUTHORITY\Authenticated Users" -AccessRights "ReadAndExecute, Synchronize" -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Add-NTFSAccess -Account SYSTEM -AccessRights FullControl -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Add-NTFSAccess -Account Administrators -AccessRights FullControl -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Set-NTFSSecurityDescriptor
            Set-NTFSOwner -Path $logsdir -Account Administrators
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            return
        }

        try {
            # Copy sshd_config_default to $sshdir\sshd_config
            $sshdConfigPath = Join-Path $sshdir "sshd_config"
            $sshddefaultconfigpath = Join-Path $OpenSSHWinPath "sshd_config_default"
            if (-not (Test-Path $sshdconfigpath -PathType Leaf)) {
                $null = Copy-Item $sshddefaultconfigpath -Destination $sshdconfigpath -Force -ErrorAction Stop
            }
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            return
        }

        try {
            if (Get-Service sshd -ErrorAction SilentlyContinue) {
               Stop-Service sshd
               sc.exe delete sshd 1>$null
            }
    
            New-Service -Name sshd -BinaryPathName "$sshdpath" -Description "SSH Daemon" -StartupType Manual | Out-Null
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            return
        }

        # Setup Host Keys
        $SSHKeyGenProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $SSHKeyGenProcessInfo.WorkingDirectory = $sshdir
        $SSHKeyGenProcessInfo.FileName = "ssh-keygen.exe"
        $SSHKeyGenProcessInfo.RedirectStandardError = $true
        $SSHKeyGenProcessInfo.RedirectStandardOutput = $true
        $SSHKeyGenProcessInfo.UseShellExecute = $false
        $SSHKeyGenProcessInfo.Arguments = "-A"
        $SSHKeyGenProcess = New-Object System.Diagnostics.Process
        $SSHKeyGenProcess.StartInfo = $SSHKeyGenProcessInfo
        $SSHKeyGenProcess.Start() | Out-Null
        $SSHKeyGenProcess.WaitForExit()
        $SSHKeyGenStdout = $SSHKeyGenProcess.StandardOutput.ReadToEnd()
        $SSHKeyGenStderr = $SSHKeyGenProcess.StandardError.ReadToEnd()
        $SSHKeyGenAllOutput = $SSHKeyGenStdout + $SSHKeyGenStderr

        if ($SSHKeyGenAllOutput -match "fail|error") {
            Write-Error $SSHKeyGenAllOutput
            Write-Error "The 'ssh-keygen -A' command failed! Halting!"
            $global:FunctionResult = "1"
            return
        }
        
        $PubPrivKeyPairFiles = Get-ChildItem -Path $sshdir | Where-Object {$_.CreationTime -gt (Get-Date).AddSeconds(-5) -and $_.Name -match "ssh_host"}
        $PubKeys = $PubPrivKeyPairFiles | Where-Object {$_.Extension -eq ".pub"}
        $PrivKeys = $PubPrivKeyPairFiles | Where-Object {$_.Extension -ne ".pub"}
        # $PrivKeys = $PubPrivKeyPairFiles | foreach {if ($PubKeys -notcontains $_) {$_}}
        
        Start-Service ssh-agent
        Start-Sleep -Seconds 5

        if ($(Get-Service "ssh-agent").Status -ne "Running") {
            Write-Error "The ssh-agent service did not start succesfully! Please check your config! Halting!"
            $global:FunctionResult = "1"
            return
        }
        
        foreach ($PrivKey in $PrivKeys) {
            $SSHAddProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
            $SSHAddProcessInfo.WorkingDirectory = $sshdir
            $SSHAddProcessInfo.FileName = "ssh-add.exe"
            $SSHAddProcessInfo.RedirectStandardError = $true
            $SSHAddProcessInfo.RedirectStandardOutput = $true
            $SSHAddProcessInfo.UseShellExecute = $false
            $SSHAddProcessInfo.Arguments = "$($PrivKey.FullName)"
            $SSHAddProcess = New-Object System.Diagnostics.Process
            $SSHAddProcess.StartInfo = $SSHAddProcessInfo
            $SSHAddProcess.Start() | Out-Null
            $SSHAddProcess.WaitForExit()
            $SSHAddStdout = $SSHAddProcess.StandardOutput.ReadToEnd()
            $SSHAddStderr = $SSHAddProcess.StandardError.ReadToEnd()
            $SSHAddAllOutput = $SSHAddStdout + $SSHAddStderr
            
            if ($SSHAddAllOutput -match "fail|error") {
                Write-Error $SSHAddAllOutput
                Write-Error "The 'ssh-add $($PrivKey.FullName)' command failed!"
            }
            else {
                if ($RemoveHostPrivateKeys) {
                    Remove-Item $PrivKey
                }
            }

            # Need to remove the above variables before next loop...
            # TODO: Make the below not necessary...
            $VariablesToRemove = @("SSHAddProcessInfo","SSHAddProcess","SSHAddStdout","SSHAddStderr","SSHAddAllOutput")
            foreach ($VarName in $VariablesToRemove) {
                Remove-Variable -Name $VarName
            }
        }

        $null = Set-Service ssh-agent -StartupType Automatic
        $null = Set-Service sshd -StartupType Automatic

        # IMPORTANT: It is important that File Permissions are "Fixed" at the end (as opposed to earlier in this function),
        # otherwise previous steps break
        if (!$(Test-Path "$OpenSSHWinPath\FixHostFilePermissions.ps1")) {
            Write-Error "The script $OpenSSHWinPath\FixHostFilePermissions.ps1 cannot be found! Permissions in the $OpenSSHWinPath directory need to be fixed before the sshd service will start successfully! Halting!"
            $global:FunctionResult = "1"
            return
        }

        try {
            & "$OpenSSHWinPath\FixHostFilePermissions.ps1" -Confirm:$false
        }
        catch {
            Write-Error "The script $OpenSSHWinPath\FixHostFilePermissions.ps1 failed! Permissions in the $OpenSSHWinPath directory need to be fixed before the sshd service will start successfully! Halting!"
            $global:FunctionResult = "1"
            return
        }
    }

    # Make sure PowerShell Core is Installed
    if (![bool]$(Get-Command pwsh -ErrorAction SilentlyContinue)) {
        # Search for pwsh.exe where we expect it to be
        $PotentialPwshExes = Get-ChildItem "$env:ProgramFiles\Powershell" -Recurse -File -Filter "*pwsh.exe"
        if (!$PotentialPwshExes) {
            try {
                Update-PowerShellCore -Latest -DownloadDirectory "$HOME\Downloads" -ErrorAction Stop
            }
            catch {
                Write-Error $_
                $global:FunctionResult = "1"
                return
            }
        }
        $PotentialPwshExes = Get-ChildItem "$env:ProgramFiles\Powershell" -Recurse -File -Filter "*pwsh.exe"
        if (!$PotentialPwshExes) {
            Write-Error "Unable to find pwsh.exe! Halting!"
            $global:FunctionResult = "1"
            return
        }
        $LatestLocallyAvailablePwsh = [array]$($PotentialPwshExes.VersionInfo | Sort-Object -Property ProductVersion)[-1].FileName
        $LatestPwshParentDir = [System.IO.Path]::GetDirectoryName($LatestLocallyAvailablePwsh)

        if ($($env:Path -split ";") -notcontains $LatestPwshParentDir) {
            # TODO: Clean out older pwsh $env:Path entries if they exist...
            $env:Path = "$LatestPwshParentDir;$env:Path"
        }
    }
    if (![bool]$(Get-Command pwsh -ErrorAction SilentlyContinue)) {
        Write-Error "Unable to find pwsh.exe! Please check your `$env:Path! Halting!"
        $global:FunctionResult = "1"
        return
    }

    $PowerShellCorePath = $(Get-Command pwsh).Source
    $PowerShellCorePathWithForwardSlashes = $PowerShellCorePath -replace "\\","/"

    ##### END Variable/Parameter Transforms and PreRun Prep #####


    ##### BEGIN Main Body #####

    # Subsystem instructions: https://github.com/PowerShell/PowerShell/tree/master/demos/SSHRemoting#setup-on-windows-machine
    [System.Collections.ArrayList]$sshdContent = Get-Content $sshdConfigPath
    if (![bool]$($sshdContent -match "Subsystem    powershell    $PowerShellCorePathWithForwardSlashes -sshs -NoLogo -NoProfile")) {
        $InsertAfterThisLine = $sshdContent -match "sftp"
        $InsertOnThisLine = $sshdContent.IndexOf($InsertAfterThisLine)+1
        $sshdContent.Insert($InsertOnThisLine, "Subsystem    powershell    $PowerShellCorePathWithForwardSlashes -sshs -NoLogo -NoProfile")
        Set-Content -Value $sshdContent -Path $sshdConfigPath
    }

    if ($DefaultShell) {
        if ($DefaultShell -eq "powershell") {
            $ForceCommandOptionLine = "ForceCommand powershell.exe -NoProfile"
        }
        if ($DefaultShell -eq "pwsh") {
            $PotentialPwshExes = Get-ChildItem "$env:ProgramFiles\Powershell" -Recurse -File -Filter "*pwsh.exe"
            $LatestLocallyAvailablePwsh = [array]$($PotentialPwshExes.VersionInfo | Sort-Object -Property ProductVersion)[-1].FileName

            $ForceCommandOptionLine = "ForceCommand `"$LatestLocallyAvailablePwsh`" -NoProfile"
        }

        [System.Collections.ArrayList]$sshdContent = Get-Content $sshdConfigPath

        # Determine if sshd_config already has the 'ForceCommand' option active
        $ExistingForceCommandOption = $sshdContent -match "ForceCommand" | Where-Object {$_ -notmatch "#"}

        # Determine if sshd_config already has 'Match User' option active
        $ExistingMatchUserOption = $sshdContent -match "Match User" | Where-Object {$_ -notmatch "#"}
        
        if (!$ExistingForceCommandOption) {
            # If sshd_config already has the 'Match User' option available, don't touch it, else add it with ForceCommand
            try {
                if (!$ExistingMatchUserOption) {
                    Add-Content -Value "Match User *`n$ForceCommandOptionLine" -Path $sshdConfigPath
                }
                else {
                    Add-Content -Value "$ForceCommandOptionLine" -Path $sshdConfigPath
                }
            }
            catch {
                Write-Error $_
                $global:FunctionResult = "1"
                return
            }
        }
        else {
            if ($ExistingForceCommandOption -ne $ForceCommandOptionLine) {
                if (!$ExistingMatchUserOption) {
                    $UpdatedSSHDConfig = $sshdContent -replace [regex]::Escape($ExistingForceCommandOption),"Match User *`n$ForceCommandOptionLine"
                }
                else {
                    $UpdatedSSHDConfig = $sshdContent -replace [regex]::Escape($ExistingForceCommandOption),"$ForceCommandOptionLine"
                }
                
                try {
                    Set-Content -Value $UpdatedSSHDConfig -Path $sshdConfigPath
                }
                catch {
                    Write-Error $_
                    $global:FunctionResult = "1"
                    return
                }
            }
        }
    }

    # Make sure port 22 is open
    if (!$(TestPort -Port 22).Open) {
        # See if there's an existing rule regarding locahost TCP port 22, if so change it to allow port 22, if not, make a new rule
        $Existing22RuleCheck = Get-NetFirewallPortFilter -Protocol TCP | Where-Object {$_.LocalPort -eq 22}
        if ($Existing22RuleCheck -ne $null) {
            $Existing22Rule =  Get-NetFirewallRule -AssociatedNetFirewallPortFilter $Existing22RuleCheck | Where-Object {$_.Direction -eq "Inbound"}
            if ($Existing22Rule -ne $null) {
                $null = Set-NetFirewallRule -InputObject $Existing22Rule -Enabled True -Action Allow
            }
            else {
                $ExistingRuleFound = $False
            }
        }
        if ($Existing22RuleCheck -eq $null -or $ExistingRuleFound -eq $False) {
            $null = New-NetFirewallRule -Action Allow -Direction Inbound -Name ssh -DisplayName ssh -Enabled True -LocalPort 22 -Protocol TCP
        }
    }

    Start-Service sshd
    Start-Sleep -Seconds 5

    if ($(Get-Service sshd).Status -ne "Running") {
        Write-Error "The sshd service did not start succesfully (within 5 seconds)! Please check your sshd_config configuration. Halting!"
        $global:FunctionResult = "1"
        return
    }

    if ($DefaultShell) {
        # For some reason, the 'ForceCommand' option is not picked up the first time the sshd service is started
        # so restart sshd service
        Restart-Service sshd
        Start-Sleep -Seconds 5

        if ($(Get-Service sshd).Status -ne "Running") {
            Write-Error "The sshd service did not start succesfully (within 5 seconds)! Please check your sshd_config configuration. Halting!"
            $global:FunctionResult = "1"
            return
        }
    }

    [pscustomobject]@{
        SSHDServiceStatus       = $(Get-Service sshd).Status
        SSHAgentServiceStatus   = $(Get-Service ssh-agent).Status
        PublicKeysPaths         = $PubKeys.FullName
        PrivateKeysPaths        = $PrivKeys.FullName
    }
}