# This function should be run on BOTH SSH Client AND SSHD Server Machines
# Output is a PSCustomObject with property [System.Collections.ArrayList] FilesUpdated and property
# [System.IO.FileInfo] SignSSHHostKeyResult
function Add-CAPubKeyToSSHAndSSHDConfig {
    [CmdletBinding(DefaultParameterSetName='VaultUrl')]
    Param(
        # NOTE: When reading 'PathToPublicKeyOfCAUsedToSign', please note that it is actually the CA's
        # **private key** that is used to do the signing. We just require the CA's public key to verify
        # that presented user keys signed by the CA's private key were, in fact, signed by the CA's private key
        [Parameter(Mandatory=$False)]
        [string]$PublicKeyOfCAUsedToSignUserKeysFilePath,

        [Parameter(Mandatory=$False)]
        [string]$PublicKeyOfCAUsedToSignUserKeysAsString,

        [Parameter(Mandatory=$False)]
        [string]$PublicKeyOfCAUsedToSignUserKeysVaultUrl, # Should be something like: http://192.168.2.12:8200/v1/ssh-client-signer/public_key

        [Parameter(Mandatory=$False)]
        [string]$PublicKeyOfCAUsedToSignHostKeysFilePath,

        [Parameter(Mandatory=$False)]
        [string]$PublicKeyOfCAUsedToSignHostKeysAsString,

        [Parameter(Mandatory=$False)]
        [string]$PublicKeyOfCAUsedToSignHostKeysVaultUrl, # Should be something like: http://192.168.2.12:8200/v1/ssh-host-signer/public_key

        [Parameter(Mandatory=$False)]
        [ValidatePattern("[\w]+@[\w]+")]
        [string[]]$AuthorizedUserPrincipals,

        [Parameter(Mandatory=$False)]
        [ValidateSet("AllUsers","LocalAdmins","LocalUsers","DomainAdmins","DomainUsers")]
        [string[]]$AuthorizedPrincipalsUserGroup,

        # Use the below $VaultSSHHostSigningUrl and $VaultAuthToken parameters if you want
        # C:\ProgramData\ssh\ssh_host_rsa_key.pub signed by the Vault Host Signing CA. This is highly recommended.
        [Parameter(Mandatory=$False)]
        [string]$VaultSSHHostSigningUrl, # Should be something like http://192.168.2.12:8200/v1/ssh-host-signer/sign/hostrole"

        [Parameter(Mandatory=$False)]
        [string]$VaultAuthToken
    )

    if ($($PSBoundParameters.Keys -match "UserKeys").Count -gt 1) {
        $ErrMsg = "The $($MyInvocation.MyCommand.Name) only takes one of the following parameters: " +
        "-PublicKeyOfCAUsedToSignUserKeysFilePath, -PublicKeyOfCAUsedToSignUserKeysAsString, -PublicKeyOfCAUsedToSignUserKeysVaultUrl"
        Write-Error $ErrMsg
    }
    if ($($PSBoundParameters.Keys -match "UserKeys").Count -eq 0) {
        $ErrMsg = "The $($MyInvocation.MyCommand.Name) MUST use one of the following parameters: " +
        "-PublicKeyOfCAUsedToSignUserKeysFilePath, -PublicKeyOfCAUsedToSignUserKeysAsString, -PublicKeyOfCAUsedToSignUserKeysVaultUrl"
        Write-Error $ErrMsg
    }

    if ($($PSBoundParameters.Keys -match "HostKeys").Count -gt 1) {
        $ErrMsg = "The $($MyInvocation.MyCommand.Name) only takes one of the following parameters: " +
        "-PublicKeyOfCAUsedToSignHostKeysFilePath, -PublicKeyOfCAUsedToSignHostKeysAsString, -PublicKeyOfCAUsedToSignHostKeysVaultUrl"
        Write-Error $ErrMsg
    }
    if ($($PSBoundParameters.Keys -match "HostKeys").Count -eq 0) {
        $ErrMsg = "The $($MyInvocation.MyCommand.Name) MUST use one of the following parameters: " +
        "-PublicKeyOfCAUsedToSignHostKeysFilePath, -PublicKeyOfCAUsedToSignHostKeysAsString, -PublicKeyOfCAUsedToSignHostKeysVaultUrl"
        Write-Error $ErrMsg
    }

    if (!$AuthorizedUserPrincipals -and !$AuthorizedPrincipalsUserGroup) {
        $AuthPrincErrMsg = "The $($MyInvocation.MyCommand.Name) function requires one of the following parameters: " +
        "-AuthorizedUserPrincipals, -AuthorizedPrincipalsUserGroup"
        Write-Error $AuthPrincErrMsg
        $global:FunctionResult = "1"
        return
    }

    if ($($VaultSSHHostSigningUrl -and !$VaultAuthToken) -or $(!$VaultSSHHostSigningUrl -and $VaultAuthToken)) {
        $ErrMsg = "If you would like this function to facilitate signing $env:ComputerName's ssh_host_rsa_key.pub, " +
        "both -VaultSSHHostSigningUrl and -VaultAuthToken parameters are required! Halting!"
        Write-Error $ErrMsg
        $global:FunctionResult = "1"
        return
    }

    # Setup our $Output Hashtable which we will add to as necessary as we go
    [System.Collections.ArrayList]$FilesUpdated = @()
    $Output = @{
        FilesUpdated = $FilesUpdated
    }


    # Make sure sshd service is installed and running. If it is, we shouldn't need to use
    # the New-SSHD server function
    if (![bool]$(Get-Service sshd -ErrorAction SilentlyContinue)) {
        if (![bool]$(Get-Service ssh-agent -ErrorAction SilentlyContinue)) {
            $InstallWinSSHSplatParams = @{
                GiveWinSSHBinariesPathPriority  = $True
                ConfigureSSHDOnLocalHost        = $True
                DefaultShell                    = "powershell"
                GitHubInstall                   = $True
                ErrorAction                     = "SilentlyContinue"
                ErrorVariable                   = "IWSErr"
            }

            try {
                $InstallWinSSHResults = Install-WinSSH @InstallWinSSHSplatParams -ErrorAction Stop
                if (!$InstallWinSSHResults) {throw "There was a problem with the Install-WinSSH function! Halting!"}

                $Output.Add("InstallWinSSHResults",$InstallWinSSHResults)
            }
            catch {
                Write-Error $_
                Write-Host "Errors for the Install-WinSSH function are as follows:"
                Write-Error $($IWSErr | Out-String)
                $global:FunctionResult = "1"
                return
            }
        }
        else {
            $NewSSHDServerSplatParams = @{
                ErrorAction         = "SilentlyContinue"
                ErrorVariable       = "SSHDErr"
                DefaultShell        = "powershell"
            }
            
            try {
                $NewSSHDServerResult = New-SSHDServer @NewSSHDServerSplatParams
                if (!$NewSSHDServerResult) {throw "There was a problem with the New-SSHDServer function! Halting!"}
            }
            catch {
                Write-Error $_
                Write-Host "Errors for the New-SSHDServer function are as follows:"
                Write-Error $($SSHDErr | Out-String)
                $global:FunctionResult = "1"
                return
            }
        }
    }

    if (Test-Path "$env:ProgramData\ssh\sshd_config") {
        $sshdir = "$env:ProgramData\ssh"
        $sshdConfigPath = "$sshdir\sshd_config"
    }
    elseif (Test-Path "$env:ProgramFiles\OpenSSH-Win64\sshd_config") {
        $sshdir = "$env:ProgramFiles\OpenSSH-Win64"
        $sshdConfigPath = "$env:ProgramFiles\OpenSSH-Win64\sshd_config"
    }
    if (!$sshdConfigPath) {
        Write-Error "Unable to find file 'sshd_config'! Halting!"
        $global:FunctionResult = "1"
        if ($Output.Count -gt 0) {[pscustomobject]$Output}
        return
    }

    if ($VaultSSHHostSigningUrl) {
        # Make sure $VaultSSHHostSigningUrl is a valid Url
        try {
            $UriObject = [uri]$VaultSSHHostSigningUrl
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }

        if (![bool]$($UriObject.Scheme -match "http")) {
            Write-Error "'$PublicKeyOfCAUsedToSignUserKeysVaultUrl' does not appear to be a URL! Halting!"
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }

        # Try to sign this machine's host key (i.e. C:\ProgramData\ssh\ssh_host_rsa_key.pub)
        try {
            # The below 'Sign-SSHHostPublicKey' function outputs a PSCustomObject detailing what was done
            # to the sshd config (if anything). It also writes out C:\ProgramData\ssh\ssh_host_rsa_key-cert.pub
            $SignSSHHostKeySplatParams = @{
                VaultSSHHostSigningUrl      = $VaultSSHHostSigningUrl
                VaultAuthToken              = $VaultAuthToken
                ErrorAction                 = "Stop"
            }
            $SignSSHHostKeyResult = Sign-SSHHostPublicKey @SignSSHHostKeySplatParams
            if (!$SignSSHHostKeyResult) {throw "There was a problem with the Sign-SSHHostPublicKey function!"}
            $Output.Add("SignSSHHostKeyResult",$SignSSHHostKeyResult)
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
    }

    # We need to get $PublicKeyOfCAUsedToSignUserKeysAsString and $PublicKeyOfCAUsedToSignHostKeysAsString
    if ($PublicKeyOfCAUsedToSignUserKeysVaultUrl) {
        # Make sure $SiteUrl is a valid Url
        try {
            $UriObject = [uri]$PublicKeyOfCAUsedToSignUserKeysVaultUrl
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }

        if (![bool]$($UriObject.Scheme -match "http")) {
            Write-Error "'$PublicKeyOfCAUsedToSignUserKeysVaultUrl' does not appear to be a URL! Halting!"
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }

        try {
            $PublicKeyOfCAUsedToSignUserKeysAsString = $(Invoke-WebRequest -Uri $PublicKeyOfCAUsedToSignUserKeysVaultUrl).Content.Trim()
            if (!$PublicKeyOfCAUsedToSignUserKeysAsString) {throw "Invoke-WebRequest failed to get the CA's Public Key from Vault! Halting!"}
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
    }
    if ($PublicKeyOfCAUsedToSignHostKeysVaultUrl) {
        # Make sure $SiteUrl is a valid Url
        try {
            $UriObject = [uri]$PublicKeyOfCAUsedToSignHostKeysVaultUrl
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }

        if (![bool]$($UriObject.Scheme -match "http")) {
            Write-Error "'$PublicKeyOfCAUsedToSignHostKeysVaultUrl' does not appear to be a URL! Halting!"
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }

        try {
            $PublicKeyOfCAUsedToSignHostKeysAsString = $(Invoke-WebRequest -Uri $PublicKeyOfCAUsedToSignHostKeysVaultUrl).Content.Trim()
            if (!$PublicKeyOfCAUsedToSignHostKeysAsString) {throw "Invoke-WebRequest failed to get the CA's Public Key from Vault! Halting!"}
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
    }
    if ($PublicKeyOfCAUsedToSignUserKeysFilePath) {
        if (! $(Test-Path $PublicKeyOfCAUsedToSignUserKeysFilePath)) {
            Write-Error "The path '$PublicKeyOfCAUsedToSignUserKeysFilePath' was not found! Halting!"
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
        
        $PublicKeyOfCAUsedToSignUserKeysAsString = Get-Content $PublicKeyOfCAUsedToSignUserKeysFilePath
    }
    if ($PublicKeyOfCAUsedToSignHostKeysFilePath) {
        if (! $(Test-Path $PublicKeyOfCAUsedToSignHostKeysFilePath)) {
            Write-Error "The path '$PublicKeyOfCAUsedToSignHostKeysFilePath' was not found! Halting!"
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
        
        $PublicKeyOfCAUsedToSignHostKeysAsString = Get-Content $PublicKeyOfCAUsedToSignHostKeysFilePath
    }

    # Now we have $PublicKeyOfCAUsedToSignUserKeysAsString and $PublicKeyOfCAUsedToSignHostKeysAsString
    # Need to make sure these strings exist in dedicated files under $sshdir as well as in 
    # $sshdir/authorized_keys and $sshdir/ssh_known_hosts

    # Before adding these CA Public Keys to $sshdir/authorized_keys, if there's already an existing
    # $sshdir/authorized_keys, archive it in a folder called $sshdir/Archive so that we can revert if necessary
    if (Test-Path "$sshdir/authorized_keys") {
        if (!$(Test-Path "$sshdir/Archive")) {
            $null = New-Item -ItemType Directory -Path "$sshdir/Archive" -Force
        }
        Move-Item -Path "$sshdir/authorized_keys" -Destination "$sshdir/Archive" -Force
    }
    # Before adding these CA Public Keys to $sshdir/ssh_known_hosts, if there's already an existing
    # $sshdir/ssh_known_hosts, archive it in a folder called $sshdir/Archive so that we can revert if necessary
    if (Test-Path "$sshdir/ssh_known_hosts") {
        if (!$(Test-Path "$sshdir/Archive")) {
            $null = New-Item -ItemType Directory -Path "$sshdir/Archive" -Force
        }
        Move-Item -Path "$sshdir/ssh_known_hosts" -Destination "$sshdir/Archive" -Force
    }

    # Add the CA Public Certs to $sshdir/authorized_keys in their appropriate formats
    Add-Content -Path "$sshdir/authorized_keys" -Value $("ssh-rsa-cert-v01@openssh.com " + "$PublicKeyOfCAUsedToSignUserKeysAsString")
    Add-Content -Path "$sshdir/authorized_keys" -Value $("ssh-rsa-cert-v01@openssh.com " + "$PublicKeyOfCAUsedToSignHostKeysAsString")
    $null = $FilesUpdated.Add($(Get-Item "$sshdir/authorized_keys"))

    # Add the CA Public Certs to $sshdir/ssh_known_hosts in their appropriate formats
    Add-Content -Path $sshdir/ssh_known_hosts -Value $("@cert-authority * " + "$PublicKeyOfCAUsedToSignUserKeysAsString")
    Add-Content -Path $sshdir/ssh_known_hosts -Value $("@cert-authority * " + "$PublicKeyOfCAUsedToSignHostKeysAsString")
    $null = $FilesUpdated.Add($(Get-Item "$sshdir/ssh_known_hosts"))

    # Make sure $PublicKeyOfCAUsedToSignUserKeysAsString and $PublicKeyOfCAUsedToSignHostKeysAsString are written
    # to their own dedicated files under $sshdir
    
    # If $PublicKeyOfCAUsedToSignUserKeysFilePath or $PublicKeyOfCAUsedToSignHostKeysFilePath were actually provided
    # maintain the same file name when writing to $sshdir
    if ($PSBoundParameters.ContainsKey('PublicKeyOfCAUsedToSignUserKeysFilePath')) {
        $UserCAPubKeyFileName = $PublicKeyOfCAUsedToSignUserKeysFilePath | Split-Path -Leaf
    }
    else {
        $UserCAPubKeyFileName = "ca_pub_key_of_client_signer.pub"
    }
    if ($PSBoundParameters.ContainsKey('PublicKeyOfCAUsedToSignHostKeysFilePath')) {
        $HostCAPubKeyFileName = $PublicKeyOfCAUsedToSignHostKeysFilePath | Split-Path -Leaf
    }
    else {
        $HostCAPubKeyFileName = "ca_pub_key_of_host_signer.pub"
    }

    if (Test-Path "$sshdir/$UserCAPubKeyFileName") {
        if (!$(Test-Path "$sshdir/Archive")) {
            $null = New-Item -ItemType Directory -Path "$sshdir/Archive" -Force
        }
        Move-Item -Path "$sshdir/$UserCAPubKeyFileName" -Destination "$sshdir/Archive" -Force
    }
    if (Test-Path "$sshdir/$HostCAPubKeyFileName") {
        if (!$(Test-Path "$sshdir/Archive")) {
            $null = New-Item -ItemType Directory -Path "$sshdir/Archive" -Force
        }
        Move-Item -Path "$sshdir/$HostCAPubKeyFileName" -Destination "$sshdir/Archive" -Force
    }

    Set-Content -Path "$sshdir/$UserCAPubKeyFileName" -Value $PublicKeyOfCAUsedToSignUserKeysAsString
    Set-Content -Path "$sshdir/$HostCAPubKeyFileName" -Value $PublicKeyOfCAUsedToSignHostKeysAsString
    $null = $FilesUpdated.Add($(Get-Item "$sshdir/$UserCAPubKeyFileName"))
    $null = $FilesUpdated.Add($(Get-Item "$sshdir/$HostCAPubKeyFileName"))
    

    # Next, we need to generate some content for $sshdir/authorized_principals

    # IMPORTANT NOTE: The Generate-AuthorizedPrincipalsFile will only ADD users to the $sshdir/authorized_principals
    # file (if they're not already in there). It WILL NOT delete or otherwise overwrite existing users in
    # $sshdir/authorized_principals
    $AuthPrincSplatParams = @{
        ErrorAction     = "Stop"
    }
    if ($(!$AuthorizedPrincipalsUserGroup -and !$AuthorizedUserPrincipals) -or
    $AuthorizedPrincipalsUserGroup -contains "AllUsers" -or
    $($AuthorizedPrincipalsUserGroup -contains "LocalAdmins" -and $AuthorizedPrincipalsUserGroup -contains "LocalUsers" -and
    $AuthorizedPrincipalsUserGroup -contains "DomainAdmins" -and $AuthorizedPrincipalsUserGroup -contains "DomainAdmins")
    ) {
        $AuthPrincSplatParams.Add("UserGroupToAdd",@("AllUsers"))
    }
    else {
        if ($AuthorizedPrincipalsUserGroup) {
            $AuthPrincSplatParams.Add("UserGroupToAdd",$AuthorizedPrincipalsUserGroup)
        }
        if ($AuthorizedUserPrincipals) {
            $AuthPrincSplatParams.Add("UsersToAdd",$AuthorizedUserPrincipals)
        }
    }

    try {
        $AuthorizedPrincipalsFile = Generate-AuthorizedPrincipalsFile @AuthPrincSplatParams
        if (!$AuthorizedPrincipalsFile) {throw "There was a problem with the Generate-AuthroizedPrincipalsFile function! Halting!"}

        $null = $FilesUpdated.Add($(Get-Item "$sshdir/authorized_principals"))        
    }
    catch {
        Write-Error $_
        $global:FunctionResult = "1"
        if ($Output.Count -gt 0) {[pscustomobject]$Output}
        return
    }

    # Now we need to fix permissions for $sshdir/authroized_principals...
    if ($(Get-Module -ListAvailable).Name -notcontains "NTFSSecurity") {
        Install-Module NTFSSecurity
    }
    try {
        if ($(Get-Module).Name -notcontains "NTFSSecurity") {Import-Module NTFSSecurity}
    }
    catch {
        if ($_.Exception.GetType().FullName -eq "System.Management.Automation.RuntimeException") {
            Write-Verbose "NTFSSecurity Module is already loaded..."
        }
        else {
            Write-Error "There was a problem loading the NTFSSecurity Module! Halting!"
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
    }

    $SecurityDescriptor = Get-NTFSSecurityDescriptor -Path "$sshdir/authorized_principals"
    $SecurityDescriptor | Disable-NTFSAccessInheritance -RemoveInheritedAccessRules
    $SecurityDescriptor | Clear-NTFSAccess
    $SecurityDescriptor | Add-NTFSAccess -Account "NT AUTHORITY\SYSTEM" -AccessRights "FullControl" -AppliesTo ThisFolderSubfoldersAndFiles
    $SecurityDescriptor | Add-NTFSAccess -Account "Administrators" -AccessRights "FullControl" -AppliesTo ThisFolderSubfoldersAndFiles
    $SecurityDescriptor | Set-NTFSSecurityDescriptor

    # Now that we have set content for $PublicKeyOfCAUsedToSignUserKeysFilePath, $sshdir/authorized_principals, and
    # $sshdir/authorized_keys, we need to update sshd_config to reference these files

    $PubKeyOfCAUserKeysFilePathForwardSlashes = "$sshdir\$UserCAPubKeyFileName" -replace '\\','/'
    $TrustedUserCAKeysOptionLine = "TrustedUserCAKeys $PubKeyOfCAUserKeysFilePathForwardSlashes"
    # For more information about authorized_principals content (specifically about setting specific commands and roles
    # for certain users), see: https://framkant.org/2017/07/scalable-access-control-using-openssh-certificates/
    $AuthPrincFilePathForwardSlashes = "$sshdir\authorized_principals" -replace '\\','/'
    $AuthorizedPrincipalsOptionLine = "AuthorizedPrincipalsFile $AuthPrincFilePathForwardSlashes"
    $AuthKeysFilePathForwardSlashes = "$sshdir\authorized_keys" -replace '\\','/'
    $AuthorizedKeysFileOptionLine = "AuthorizedKeysFile	$AuthKeysFilePathForwardSlashes"

    [System.Collections.ArrayList]$sshdContent = Get-Content $sshdConfigPath

    # Determine if sshd_config already has the 'TrustedUserCAKeys' option active
    $ExistingTrustedUserCAKeysOption = $sshdContent -match "TrustedUserCAKeys" | Where-Object {$_ -notmatch "#"}

    # Determine if sshd_config already has 'AuthorizedPrincipals' option active
    $ExistingAuthorizedPrincipalsFileOption = $sshdContent -match "AuthorizedPrincipalsFile" | Where-Object {$_ -notmatch "#"}

    # Determine if sshd_config already has 'AuthorizedKeysFile' option active
    $ExistingAuthorizedKeysFileOption = $sshdContent -match "AuthorizedKeysFile" | Where-Object {$_ -notmatch "#"}
    
    if (!$ExistingTrustedUserCAKeysOption) {
        # If sshd_config already has the 'Match User' option available, don't touch it, else add it with ForceCommand
        try {
            Add-Content -Value $TrustedUserCAKeysOptionLine -Path $sshdConfigPath
            $SSHDConfigContentChanged = $True
            [System.Collections.ArrayList]$sshdContent = Get-Content $sshdConfigPath
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
    }
    else {
        if ($ExistingTrustedUserCAKeysOption -ne $TrustedUserCAKeysOptionLine) {
            $UpdatedSSHDConfig = $sshdContent -replace [regex]::Escape($ExistingTrustedUserCAKeysOption),"$TrustedUserCAKeysOptionLine"

            try {
                Set-Content -Value $UpdatedSSHDConfig -Path $sshdConfigPath
                $SSHDConfigContentChanged = $True
                [System.Collections.ArrayList]$sshdContent = Get-Content $sshdConfigPath
            }
            catch {
                Write-Error $_
                $global:FunctionResult = "1"
                if ($Output.Count -gt 0) {[pscustomobject]$Output}
                return
            }
        }
        else {
            Write-Warning "The specified 'TrustedUserCAKeys' option is already active in the the sshd_config file. No changes made."
        }
    }

    if (!$ExistingAuthorizedPrincipalsFileOption) {
        try {
            Add-Content -Value $AuthorizedPrincipalsOptionLine -Path $sshdConfigPath
            $SSHDConfigContentChanged = $True
            [System.Collections.ArrayList]$sshdContent = Get-Content $sshdConfigPath
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
    }
    else {
        if ($ExistingAuthorizedPrincipalsFileOption -ne $AuthorizedPrincipalsOptionLine) {
            $UpdatedSSHDConfig = $sshdContent -replace [regex]::Escape($ExistingAuthorizedPrincipalsFileOption),"$AuthorizedPrincipalsOptionLine"

            try {
                Set-Content -Value $UpdatedSSHDConfig -Path $sshdConfigPath
                $SSHDConfigContentChanged = $True
                [System.Collections.ArrayList]$sshdContent = Get-Content $sshdConfigPath
            }
            catch {
                Write-Error $_
                $global:FunctionResult = "1"
                if ($Output.Count -gt 0) {[pscustomobject]$Output}
                return
            }
        }
        else {
            Write-Warning "The specified 'AuthorizedPrincipalsFile' option is already active in the the sshd_config file. No changes made."
        }
    }

    if (!$ExistingAuthorizedKeysFileOption) {
        try {
            Add-Content -Value $AuthorizedKeysFileOptionLine -Path $sshdConfigPath
            $SSHDConfigContentChanged = $True
            [System.Collections.ArrayList]$sshdContent = Get-Content $sshdConfigPath
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
    }
    else {
        if ($ExistingAuthorizedKeysFileOption -ne $AuthorizedKeysFileOptionLine) {
            $UpdatedSSHDConfig = $sshdContent -replace [regex]::Escape($ExistingAuthorizedKeysFileOption),"$AuthorizedKeysFileOptionLine"

            try {
                Set-Content -Value $UpdatedSSHDConfig -Path $sshdConfigPath
                $SSHDConfigContentChanged = $True
                [System.Collections.ArrayList]$sshdContent = Get-Content $sshdConfigPath
            }
            catch {
                Write-Error $_
                $global:FunctionResult = "1"
                if ($Output.Count -gt 0) {[pscustomobject]$Output}
                return
            }
        }
        else {
            Write-Warning "The specified 'AuthorizedKeysFile' option is already active in the the sshd_config file. No changes made."
        }
    }

    if ($SSHDConfigContentChanged) {
        $null = $FilesUpdated.Add($(Get-Item $sshdConfigPath))
        
        try {
            Restart-Service sshd -ErrorAction Stop
        }
        catch {
            Write-Error $_
            $global:FunctionResult = "1"
            if ($Output.Count -gt 0) {[pscustomobject]$Output}
            return
        }
    }

    [pscustomobject]$Output
}