<#
.SYNOPSIS
    Update local hp repo with latest required softpaqs and BIOS bin files

.DESCRIPTION
    Requires PowerShell 7. This script updates a local HP repository of Softpaqs and BIOS bin files for a given list of HP Product Codes and OS versions.
    Configuration CABs are downloaded for each model.  A de-duped list of softpaqs is prepared and CVAs and EXEs are downloaded
    for all softpaqs. If a local EXE already exists, it is hash-checked for verification.  Softpaq processing is done via parallel
    processing threads. The latest BIOS bin for each model is
    also downloaded.

.PARAMETER ModelsJSON
    Path to JSON file with a list of models and OS versions to be included in the repo.

    Sample expected JSON structure:
    [
        {"ProdCode": "826B", "Model": "HP ZBOOK STUDIO G4", "OSVER": 1709},
        {"ProdCode": "8270", "Model": "HP ZBOOK 17 G4", "OSVER": 1903}
    ]

.PARAMETER logfile
    Path for desired log file output

.PARAMETER softpaqTemp
    Path to a local temp folder for an offline copy of the softpaq repo.  The script will run the repo sync to this local copy and use this copy for all
    hash validation.  Once the local repo sync has completed successfully, the changes get robocopy'd to the final/published location (softpaqFinal parameter)

.PARAMETER softpaqFinal
    Path to the final/published softpaq repository location.  This is most likely a network share or DFS source folder.

.PARAMETER biosTemp
    Path to a local temp folder for an offline copy of the latest BIOS bin files.  The script will run the sync to this local copy.  Once the local
    sync has completed successfully, the changes get robocopy'd to the final/published location (biosFinal parameter)

.PARAMETER biosFinal
    Path to the final/published bios repository location.  This is most likely a network share or DFS source folder.

.PARAMETER cabTemp
    Path to the local folder where the model config CABs will be downloaded and extracted.

.PARAMETER MaxThreads
    This value is passed to the ThrottleLimit paramater of the 'ForEach-Object -Parallel' cmdlet. This sets the maximum number of simultaneous softpaq
    processing threads that will be allowed to execute concurrently.

.EXAMPLE
    Sync-HPRepository.ps1 -ModelsJSON ".\Models.json" -softpaqTemp ".\spTemp" -softpaqFinal "\\server\HPRepo\softpaqs" `
        -biosTemp ".\biosTemp" -biosFinal "\\server\HPRepo\bios" -cabTemp ".\cabs"

.NOTES
	FileName:    Sync-HPRepository.ps1
    Author:      Justin Holloman
	Created:     2020-03-02
	Version:     1.0.1
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true,
               ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true)]
    [ValidateScript({Test-Path $_})]
    [string]$ModelsJSON
    
    ,[Parameter(Mandatory=$false,
               ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$logfile = "$PSScriptRoot\Sync-HPRepository.log"

    ,[Parameter(Mandatory=$true,
               ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true)]
    [ValidateScript({Test-Path $_})]
    [string]$softpaqTemp

    ,[Parameter(Mandatory=$true,
               ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true)]
    [ValidateScript({Test-Path $_})]
    [string]$softpaqFinal

    ,[Parameter(Mandatory=$true,
               ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true)]
    [ValidateScript({Test-Path $_})]
    [string]$biosTemp

    ,[Parameter(Mandatory=$true,
               ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true)]
    [ValidateScript({Test-Path $_})]
    [string]$biosFinal

    ,[Parameter(Mandatory=$true,
               ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true)]
    [ValidateScript({Test-Path $_})]
    [string]$cabTemp

    ,[Parameter(Mandatory=$false,
               ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$true)]
    [ValidateRange(1,20)]
    [int32]$MaxThreads = 5
)

#region Initialization
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$scriptVersion = "1.0.1"

$scriptroot = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$failuresPath = "$scriptroot\failures"
        
# synched hastable to use for returning data from parallel runspaces
$logVar = [hashtable]::Synchronized(@{})

# Init log file if necessary
if (-not (Test-Path -Path $logfile)) {
    New-Item -Path $logfile -ItemType File -Force | Out-Null
}

# clear the cabs folder
Get-ChildItem -Path $cabTemp | Remove-Item -Recurse -Force

# clear the failures folder
Get-ChildItem -Path $failuresPath | Remove-Item -Recurse -Force

# import required modules
try {
    Import-Module HP.ClientManagement -ErrorAction Stop
    Import-Module HP.Private -ErrorAction Stop
}
catch {
    throw "Failed to import required modules.  Install HP Client Management Script Library and try again."
}
#endregion

#region functions
function Write-Log {
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Path = $logfile,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Info","Warn","Error")]
        [string]$Level = "Info",

        [Parameter(Mandatory = $false)]
        [string]$Component = "",

        [Parameter(Mandatory = $false)]
        [string]$Thread = "",

        [Parameter(Mandatory = $false)]
        [string]$Filename = ""
    )

    # Format Date for our Log File
    $FormattedDate = Get-Date -Format "MM-dd-yyyy"
    $FormattedTime = Get-Date -Format "HH:mm:ss.fffffff"

    # Write message to error, warning, or verbose pipeline and specify $LevelText
    switch ($Level) {
        'Error' {
            Write-Warning $Message
            $LevelText = '3'
            }
        'Warn' {
            Write-Warning $Message
            $LevelText = '2'
            }
        'Info' {
            Write-Verbose $Message
            $LevelText = '1'
            }
        }

    # Write log entry to $Path
    #"$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Append
    '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="{6}">' -f $message,$FormattedTime,$FormattedDate,$Component,$LevelText,$Thread,$Filename | Out-File -FilePath $Path -Append -Encoding UTF8
}

function DownloadFile {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)]
        [string]$Url

        ,[Parameter(Mandatory=$true)]
        [string]$Destination

        ,[Parameter(Mandatory=$false)]
        [int32]$MaxAttempts = 3

        ,[Parameter(Mandatory=$false)]
        [int32]$RetryDelay = 10
    )

    $wc = New-Object System.Net.WebClient

    # Must attempt at least once
    if ($MaxAttempts -lt 1) {$MaxAttempts = 1}

    $attempt = 1
    $success = $false
    while ($success -eq $false) {
        if ($attempt -le $MaxAttempts) {
            try {
                #Write-Verbose "Starting download: $Url  Destination: $Destination"
                $wc.DownloadFile($Url, $Destination)
                return
            }
            catch {
                $attempt++
            }
        }
        else {
            throw "Failed $MaxAttempts times to download $Url"
        }
    }
}

<#
    Adapted from Get-SoftpaqList from HP.Softpaq module (HP CMSL 1.4.1)
#>
function ImportPlatformXML {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)]
        [string]$downloadedFile
    )

    Write-Verbose "Reading XML document  $downloadedFile"
    [xml]$data = Get-Content $downloadedFile
    Write-Verbose "Parsing the document"

    $d = Select-Xml -Xml $data -XPath "//ImagePal/Solutions/UpdateInfo"

    $results = @()
    $d | ForEach-Object {
        $results += [PSCustomObject]@{
            "Id" = $_.Node.id
            "Name" = $_.Node.Name
            "Category" = $_.Node.category
            "Version" = $_.Node.Version
            "Vendor" = $_.Node.Vendor
            "ReleaseType" = $_.Node.releaseType
            "SSM" = $_.Node.SSMCompliant
            "DPB" = $_.Node.DPBCompliant
            "Url" = $_.Node.Url
            "ReleaseNotes" = $_.Node.ReleaseNotesUrl
            "Metadata" = $_.Node.CvaUrl
            "MD5" = $_.Node.md5
            "Size" = $_.Node.Size
            "ReleaseDate" = $_.Node.DateReleased
        }
    }

    return $results
}
#endregion

Write-Log -Message "======== Sync-HPRepository.ps1 (v$($ScriptVersion)) ========"

#region download model CABs and build a list of distinct Softpaqs to include
# retrieve models to include in repository
if (Test-Path -Path $ModelsJSON) {
    try {
        Write-Log -Message "Reading model list from [$ModelsJSON]."
        $HPModelsTable = @(Get-Content -Path $ModelsJSON -Raw | ConvertFrom-Json)
        Write-Log -Message "Found $($HPModelsTable.Count) model(s) to import."
    }
    catch {
        Write-Log -Message $Error[0].Exception.Message -Level Error
        $msg = "Failed to import JSON model info.  Check that JSON file exists and JSON formatting is valid."
        Write-Log -Message $msg -Level Error
        throw $msg
    }
}
else {
    Write-Log -Message $Error[0].Exception.Message -Level Error
    $msg = "Failed to locate JSON file with model info.  Check the supplied path."
    Write-Log -Message $msg -Level Error
    throw $msg
}

$softpaqs = @{}
foreach ($model in $HPModelsTable) {
    Write-Log -Message ("Getting softpaqs for {0} ({1}) for Windows 10 {2}" -f $model.Model, $model.ProdCode, $model.OSVER)
    $platform = $model.ProdCode.ToLower()
    $build = $model.OSVER
    $cabURL = "https://ftp.hp.com/pub/caps-softpaq/cmit/imagepal/ref/$platform/$($platform)_64_10.0.$build.cab"

    DownloadFile -Url $cabURL -Destination "$cabTemp\$($platform)_64_10.0.$build.cab"
    $xmlPath = Invoke-HPPrivateExpandCAB -cab "$cabTemp\$($platform)_64_10.0.$build.cab" -expectedFile "$cabTemp\$($platform)_64_10.0.$build.cab.dir/$($platform)_64_10.0.$build.xml"
    $results = ImportPlatformXML -downloadedFile $xmlPath
    
    $results | ForEach-Object {
        if ($softpaqs.ContainsKey($_.Id)) {
            #Write-Host ("Skipping {0} as it is already in the list" -f $_.Id)
        }
        else {
            #Write-Host ("Adding {0}" -f $_.Id)
            $softpaqs.Add($_.Id,$_)
        }
    }
}

# for my environment, I want everything except driver packs and BIOS softpaqs (BIOS bin files will be downloaded separately later, as I deploy those via another mechanism)
# also filter out softpaqs that can't be installed silently (SSM-compliant only)
$keepers = $softpaqs.Values | ?{($_.Category -notlike '*Driver Pack*') -and ($_.Category -ine 'BIOS') -and ($_.SSM -eq $true)} | Sort-Object Id
Write-Log -Message "Discovered $($keepers.Count) softpaqs to be included in the repository."
#endregion

#region synchronize local BIOS BIN repo
Set-Location -Path $BiosTemp -ErrorAction Stop
Write-Log -Message "Getting bios BIN files..."
foreach ($model in $HPModelsTable)
{
    try {
        # Get latest bios version
        $bin = $null
        Write-Log -Message "    Getting latest bios version number for model: $($model.ProdCode)"
        $bin = Get-HPBiosUpdates -latest -platform $model.ProdCode | %{$_.Bin}
    
        # Download it if we don't already have it
        if (-not (Get-ChildItem -Path $BiosTemp -Name $bin))
        {
            Write-Log -Message "    Downloading latest bios for model: $($model.ProdCode)"
            Get-HPBiosUpdates -download -overwrite -platform $model.ProdCode
        }
        else
        {
            Write-Log -Message "    BIOS already present for model: $($model.ProdCode)"
        }
    }
    catch {
        Write-Log -Message $Error[0].Exception.Message -Level Error
        Write-Log -Message "    Failed to get BIOS bin file for model $($model.ProdCode)" -Level Error
    }
}
#endregion

#region synchronize local Softpaq Repo
Set-Location -Path $softpaqTemp -ErrorAction Stop
Write-Log -Message "Beginning parallel execution. This log will update once all threads are complete."

# for each softpaq, download and validate the hash. if a local copy of the exe is already found, validate the hash to check it.
# wrap each object in a pscustomobject wrapper in order to include an editable reference to the synchronized hashtable inside the parallel scripblock
# Maybe there's a better way to do this, but I couldn't find any other way to pass additional arguments in to the parallel scriptblock other than the pipeline
$keepers | ForEach-Object {[pscustomobject] @{logVar = $logVar; Item = $_}} | ForEach-Object -ThrottleLimit $MaxThreads -Parallel {
    $sp = $_.Item
    $script:logBuilder = @()

    #region functions
    function Write-LogVar {
        [CmdletBinding()]
        Param
        (
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$Message,

            [Parameter(Mandatory = $false)]
            [ValidateSet("Info","Warn","Error")]
            [string]$Level = "Info",

            [Parameter(Mandatory = $false)]
            [string]$Component = "",

            [Parameter(Mandatory = $false)]
            [string]$Thread = "",

            [Parameter(Mandatory = $false)]
            [string]$Filename = ""
        )

        # Format Date for our Log File
        $FormattedDate = Get-Date -Format "MM-dd-yyyy"
        $FormattedTime = Get-Date -Format "HH:mm:ss.fffffff"

        # Write message to error, warning, or verbose pipeline and specify $LevelText
        switch ($Level) {
            'Error' {
                Write-Warning $Message
                $LevelText = '3'
                }
            'Warn' {
                Write-Warning $Message
                $LevelText = '2'
                }
            'Info' {
                Write-Verbose $Message
                $LevelText = '1'
                }
            }

        # Write log entry to log variable
        $script:logBuilder += ('<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="{6}">' -f $message,$FormattedTime,$FormattedDate,$Component,$LevelText,$Thread,$Filename)
    }

    function GetCvaSection {
        [CmdletBinding()]
        Param
        (
            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [Object[]]$cva,
    
            [Parameter(Mandatory=$true)]
            [string]$Section
        )
    
        [int32]$titleIndex = -1
    
        for ($i = 0; $i -lt $cva.Count; $i++) {
            if ($cva[$i] -match "^\[$Section\]") {
                $titleIndex = $i
                break
            }
        }
    
        if ($titleIndex -eq -1) {
            return $null
        }
        else {
            [string[]]$contents = @()
            [boolean]$stillInSection = $true
            [int32]$index = $titleIndex + 1
    
            while ($stillInSection) {
                if ($cva[$index].Trim() -eq '') {
                    $stillInSection = $false
                }
                else {
                    $contents = $contents + $cva[$index]
                    $index++
                }
            }
    
            return $contents
        }
    }

    function DownloadSoftpaq {
        [CmdletBinding()]
        Param(
            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$SoftpaqId,

            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$CvaUrl,

            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$ExeUrl,

            [Parameter(Mandatory=$false)]
            [string]$Destination = $using:softpaqTemp
        )

        #region Get CVA
        ## Validate CvaUrl formatting
        if ($CvaUrl -imatch '^(http(?:s)?:\/\/)?.*(sp\d{5,6}\.cva)$') {
            ## extract the filename for use later
            $filename = $matches[2]

            ## always use HTTPS
            if ($matches[1] -ieq 'http://') {
                ## replace http with https
                $CvaUrl = $CvaUrl -ireplace '^http:\/\/', 'https://'
            }
            elseif ($matches[1] -ieq 'https://') {
                ## looks good
            }
            else {
                ## missing the https prefix, add it
                $CvaUrl = "https://$CvaUrl"
            }
        }
        else {
            throw "Not a valid CVA url: $CvaUrl"
        }

        # Download CVA to destination folder
        Write-LogVar -Message "Downloading $CvaUrl"
        $output = "$Destination\$filename"

        try {
            DownloadFile -Url $CvaUrl -Destination $output
        }
        catch {
            throw "Failed to download CVA file."
        }

        if (-not (Test-Path $output)) {
            ## file should be here, but it's not
            throw "Failed to download CVA file."
        }

        ## Read CVA into array
        $cva = Get-Content -Path $output

        # Get Softpaq hashes
        $Contents = GetCvaSection -cva $cva -Section 'Softpaq'
        if ($null -eq $Contents) {
            throw "Failed to parse CVA file"
        }
        else {
            $SoftPaqMD5 = $null
            $SoftPaqSHA256 = $null

            foreach ($line in $Contents) {
                if ($line -imatch '^SoftPaqMD5=(.*)') {
                    $SoftPaqMD5 = $matches[1]
                }
                elseif ($line -imatch '^SoftPaqSHA256=(.*)') {
                    $SoftPaqSHA256 = $matches[1]
                }
            }

            if (($null -eq $SoftPaqMD5) -and ($null -eq $SoftPaqSHA256)) {
                throw "Failed to obtain EXE hash values from CVA"
            }
        }
        #endregion

        #region Get EXE
        ## Validate ExeUrl formatting
        if ($ExeUrl -imatch '^(http(?:s)?:\/\/)?.*(sp\d{5,6}\.exe)$') {
            ## extract the filename for use later
            $filename = $matches[2]

            ## always use HTTPS
            if ($matches[1] -ieq 'http://') {
                ## replace http with https
                $ExeUrl = $ExeUrl -ireplace '^http:\/\/', 'https://'
            }
            elseif ($matches[1] -ieq 'https://') {
                ## looks good
            }
            else {
                ## missing the https prefix, add it
                $ExeUrl = "https://$ExeUrl"
            }
        }
        else {
            throw "Not a valid EXE url: $ExeUrl"
        }
        
        ## Check local folder in case we've already downloaded this before
        $output = "$Destination\$filename"
        $AlreadyDownloaded = $false
        if (Test-Path $output) {
            Write-LogVar -Message "Existing local EXE found.  Checking hash."
            if (ValidateHash -Path $output -Algorithm "MD5" -Hash $SoftPaqMD5 -ErrorAction SilentlyContinue) {
                $AlreadyDownloaded = $true
                Write-LogVar -Message "Existing local copy passed MD5 hash check. Skipping download."
            }
            else {
                Write-LogVar -Message "Existing local copy of $SoftpaqId failed MD5 hash check. Will Redownload." -Level Warn
                Remove-Item -Path $output -Force
            }
        }

        if (-not $AlreadyDownloaded) {
            # Download EXE to destination folder
            Write-LogVar -Message "Downloading $ExeUrl"
            try {
                DownloadFile -Url $ExeUrl -Destination $output
            }
            catch {
                throw "Failed to download EXE file."
            }

            if (Test-Path $output) {                
                if (ValidateHash -Path $output -Algorithm "MD5" -Hash $SoftPaqMD5 -ErrorAction SilentlyContinue) {
                    Write-LogVar -Message "Download passed MD5 hash check."
                }
                else {
                    Write-LogVar -Message "Download of $SoftpaqId failed MD5 hash check." -Level Warn
                    throw "Failed hash check."
                }
            }
            else {
                throw "Failed to download EXE file."
            }
        }
        #endregion
    }

    function ValidateHash {
        [CmdletBinding()]
        Param (
            [Parameter(Mandatory=$true)]
            [string]$Path

            ,[Parameter(Mandatory=$true)]
            [ValidateSet("MD5","SHA256")]
            [string]$Algorithm

            ,[Parameter(Mandatory=$true)]
            [string]$Hash
        )

        $filehash = Get-FileHash -Path $Path -Algorithm $Algorithm -ErrorAction Stop
            
        if ($filehash.Hash -ieq $Hash) {
            Write-LogVar -Message "Hash verified: Expected = [$Hash] Actual = [$($filehash.Hash)]"
            return $true
        }
        else {
            Write-LogVar -Message "Hash mismatch: Expected = [$Hash] Actual = [$($filehash.Hash)]" -Level Warn
            return $false
        }
    }

    function DownloadFile {
        [CmdletBinding()]
        Param (
            [Parameter(Mandatory=$true)]
            [string]$Url

            ,[Parameter(Mandatory=$true)]
            [string]$Destination

            ,[Parameter(Mandatory=$false)]
            [int32]$MaxAttempts = 3

            ,[Parameter(Mandatory=$false)]
            [int32]$RetryDelay = 10
        )

        $wc = New-Object System.Net.WebClient

        # Must attempt at least once
        if ($MaxAttempts -lt 1) {$MaxAttempts = 1}

        $attempt = 1
        $success = $false
        while ($success -eq $false) {
            if ($attempt -le $MaxAttempts) {
                try {
                    $wc.DownloadFile($Url, $Destination)
                    return
                }
                catch {
                    $attempt++
                }
            }
            else {
                throw "Failed $MaxAttempts times to download $Url"
            }
        }
    }
    #endregion

    try {
        Write-LogVar -Message "-----"
        Write-LogVar -Message "Begin processing $($sp.Id)"
        DownloadSoftpaq -CvaUrl $sp.Metadata -ExeUrl $sp.Url -SoftpaqId $sp.Id
        Write-LogVar -Message "Finished processing $($sp.Id)"
    }
    catch {
        Write-LogVar -Message "Error while obtaining softpaq $($sp.Id)." -Level Error
        New-Item -Path "$using:failuresPath\$($sp.Id).marker" -ItemType File -Force | Out-Null
    }
    finally {
        # add log results to synced log variable
        $_.logVar.Add($sp.Id,$logBuilder)
    }
}

# dump all the log entries from synced hashtable into log file
Write-Log -Message "Finished parallel download processing."
Write-Log -Message "Begin log output from parallel threads:"
$logVar.GetEnumerator() | Sort-Object Key | ForEach-Object {
    $softpaqId = $_.Key
    $logEntries = @($_.Value)


    foreach ($entry in $logEntries) {
        $entry | Out-File -FilePath $logfile -Append -Encoding UTF8
    }
}
Write-Log -Message "-----"
Write-Log -Message "End log output from parallel threads."

# record which downloads failed
$failures = Get-ChildItem -Path $failuresPath -Name "*.marker"

if ($failures.Count -gt 0) {
    Write-Log -Message "The following $($failures.Count) softpaq(s) failed to download or failed the hash check:" -Level Warn
    $failures | ForEach-Object { Write-Log -Message ($_.PSChildName -ireplace "\.marker","") -Level Warn }
}
else {
    Write-Log -Message "All softpaqs downloaded successfully."
}

# clean up stale softpaqs
Write-Log -Message "Cleaning up repo to remove Softpaqs that are no longer needed."
$existingEXEs = Get-ChildItem -Path $softpaqTemp -Name "*.exe"
$existingEXEs.GetEnumerator() | ForEach-Object {
    $id = $_.PSChildName -ireplace "\.exe", ""
    if ($keepers.Id -inotcontains $id) {
        Write-Log -Message "$id is no longer referenced by any model configuration.  Removing from repo."
        Remove-Item -Path $_.PSPath -Force
    }
}

# clean up unmatched CVA files
Write-Log -Message "Removing unmatched CVA files from repo."
$existingEXEs = Get-ChildItem -Path $softpaqTemp -Name "*.exe"
$existingCVAs = Get-ChildItem -Path $softpaqTemp -Name "*.cva"

$existingCVAs.GetEnumerator() | ForEach-Object {
    $matchingExe = $_.PSChildName -ireplace "\.cva", ".exe"
    if (-not (Test-Path -Path "$softpaqTemp\$matchingExe")) {
        Write-Log -Message "No matching EXE for $($_.PSChildName).  Removing from repo."
        Remove-Item -Path $_.PSPath -Force
    }
}
#endregion

#region replicate local Softpaq and BIN repos to published locations
# copy softpaqs to final repo location
Write-Log -Message "Begin Robocopy repo to $softpaqFinal"
Start-Process -FilePath "robocopy.exe" -ArgumentList "$softpaqTemp $softpaqFinal /MIR" -Wait -ErrorAction Stop
Write-Log -Message "Robocopy complete"

# copy bios to final repo location
Write-Log -Message "Begin Robocopy bios to $biosFinal"
Start-Process -FilePath "robocopy.exe" -ArgumentList "$biosTemp $biosFinal *.bin /MIR" -Wait -ErrorAction Stop
Write-Log -Message "Robocopy complete"
#endregion
#>