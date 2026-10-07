#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

$ConfigFile = "lua-definitions.json"
$ManifestName = ".lua-definitions-sync"

$global:Warnings = 0
$global:Errors = 0

function Write-LogInfo([string]$Message) { Write-Host "  [i] $Message" -ForegroundColor Cyan }
function Write-LogSuccess([string]$Message) { Write-Host "  [+] $Message" -ForegroundColor Green }
function Write-LogWarning([string]$Message) { Write-Host "  [!] WARNING: $Message" -ForegroundColor Yellow; $global:Warnings++ }
function Write-LogError([string]$Message) { Write-Host "  [X] ERROR: $Message" -ForegroundColor Red; $global:Errors++ }

if (-Not (Test-Path $ConfigFile)) {
    Write-LogError "Config file not found: $ConfigFile"
    exit 1
}

$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$TargetDir = if ($Config.target_dir) { $Config.target_dir } else { "./definitions_vendor" }
$Token = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN")
$ManifestFile = Join-Path $TargetDir $ManifestName

function Invoke-GithubApi {
    param([string]$Url)
    $Headers = @{
        "Accept" = "application/vnd.github.v3+json"
        "User-Agent" = "Lua-Definitions-Sync"
    }
    if ($Token) {
        $Headers["Authorization"] = "Bearer $Token"
    }
    try {
        return Invoke-RestMethod -Uri $Url -Headers $Headers
    } catch {
        Write-LogError "Error accessing $Url : $_"
        return $null
    }
}

function Download-File {
    param([string]$Url, [string]$Dest)
    $Dir = Split-Path $Dest
    if (-Not (Test-Path $Dir)) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    }

    $Headers = @{ "User-Agent" = "Lua-Definitions-Sync" }
    if ($Token) {
        $Headers["Authorization"] = "Bearer $Token"
    }
    try {
        Invoke-WebRequest -Uri $Url -Headers $Headers -OutFile $Dest -UseBasicParsing
        Write-LogSuccess "Downloaded: $Dest"
    } catch {
        Write-LogError "Failed to download $Url : $_"
    }
}

# Returns the normalized dest, or $null if it could escape or wipe the target directory
function Get-NormalizedDest([string]$Dest) {
    if ([string]::IsNullOrWhiteSpace($Dest)) { return $null }
    $d = $Dest -replace '\\', '/'
    while ($d.StartsWith("./")) { $d = $d.Substring(2) }
    $d = $d.TrimEnd('/')
    if ($d -eq "" -or $d.StartsWith("/") -or $d -match '^[A-Za-z]:') { return $null }
    foreach ($seg in $d.Split('/')) {
        if ($seg -eq "" -or $seg -eq "." -or $seg -eq "..") { return $null }
    }
    return $d
}

# True if dest paths are equal or one contains the other
function Test-DestOverlap([string]$A, [string]$B) {
    return ($A -eq $B) -or $A.StartsWith("$B/") -or $B.StartsWith("$A/")
}

function Process-Entry {
    param(
        [Parameter(Mandatory=$true)] [AllowNull()] $Data,
        [string]$Owner,
        [string]$Repo,
        [string]$Ref,
        [string]$DestDir,
        [string]$Pattern,
        [bool]$Recursive
    )

    if ($null -eq $Data) { return }

    # GitHub API returns an array for directories and a single object for files
    $IsArray = $Data -is [System.Object[]]

    # Handle single file
    if (-not $IsArray -and $Data.type -eq "file") {
        if ([string]::IsNullOrEmpty($Pattern) -or ($Data.name -like $Pattern)) {
            $TargetPath = Join-Path $DestDir $Data.name
            Download-File -Url $Data.download_url -Dest $TargetPath
        }
        return
    }

    # Handle directory
    if ($IsArray) {
        foreach ($item in $Data) {
            if ($item.type -eq "file") {
                if ([string]::IsNullOrEmpty($Pattern) -or ($item.name -like $Pattern)) {
                    $TargetPath = Join-Path $DestDir $item.name
                    Download-File -Url $item.download_url -Dest $TargetPath
                }
            } elseif ($item.type -eq "dir" -and $Recursive) {
                $SubUrl = "https://api.github.com/repos/$Owner/$Repo/contents/$($item.path)?ref=$Ref"
                $SubData = Invoke-GithubApi -Url $SubUrl
                $SubDestDir = Join-Path $DestDir $item.name
                Process-Entry -Data $SubData -Owner $Owner -Repo $Repo -Ref $Ref -DestDir $SubDestDir -Pattern $Pattern -Recursive $Recursive
            }
        }
    }
}

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
$StagingRoot = Join-Path $TargetDir (".sync-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $StagingRoot | Out-Null

$CurrentDests = @()
try {
    $Index = 0
    foreach ($source in $Config.sources) {
        $Index++
        $Ref = if ($source.ref) { $source.ref } else { "main" }
        $RawDest = if ($source.dest) { $source.dest } else { $source.id }

        $DestName = Get-NormalizedDest $RawDest
        if ($null -eq $DestName) {
            Write-LogError "Skipping $($source.id): invalid dest '$RawDest' (must be a relative path inside target_dir)"
            continue
        }

        $Overlap = $CurrentDests | Where-Object { Test-DestOverlap $DestName $_ } | Select-Object -First 1
        if ($Overlap) {
            Write-LogError "Skipping $($source.id): dest '$DestName' overlaps another source's dest '$Overlap'"
            continue
        }
        $CurrentDests += $DestName

        $DestFolder = Join-Path $TargetDir $DestName
        $StagingFolder = Join-Path $StagingRoot $Index
        New-Item -ItemType Directory -Force -Path $StagingFolder | Out-Null
        $ErrorsBefore = $global:Errors

        Write-LogInfo "Fetching $($source.id) ($($source.owner)/$($source.repo) @ $Ref)..."

        foreach ($pathItem in $source.paths) {
            $Pattern = if ($pathItem.pattern) { $pathItem.pattern } else { "*.lua" }
            $Recursive = if ($null -ne $pathItem.recursive) { [bool]$pathItem.recursive } else { $false }

            $Url = "https://api.github.com/repos/$($source.owner)/$($source.repo)/contents/$($pathItem.path)?ref=$Ref"
            $Data = Invoke-GithubApi -Url $Url

            Process-Entry -Data $Data -Owner $source.owner -Repo $source.repo -Ref $Ref -DestDir $StagingFolder -Pattern $Pattern -Recursive $Recursive
        }

        # Only replace the previous files once everything downloaded cleanly
        if ($global:Errors -gt $ErrorsBefore) {
            Write-LogWarning "Keeping previous files for $($source.id) in $DestFolder due to errors."
        } else {
            if (Test-Path $DestFolder) {
                Remove-Item -Recurse -Force $DestFolder
            }
            $DestParent = Split-Path $DestFolder
            if (-Not (Test-Path $DestParent)) {
                New-Item -ItemType Directory -Force -Path $DestParent | Out-Null
            }
            Move-Item -Path $StagingFolder -Destination $DestFolder
            Write-LogSuccess "Updated: $DestFolder"
        }
    }

    # Remove folders from sources that were dropped from the config since the last sync
    if (Test-Path $ManifestFile) {
        foreach ($OldRaw in Get-Content $ManifestFile) {
            $Old = Get-NormalizedDest $OldRaw
            if ($null -eq $Old) { continue }
            $Keep = $CurrentDests | Where-Object { Test-DestOverlap $Old $_ }
            $OldFolder = Join-Path $TargetDir $Old
            if (-not $Keep -and (Test-Path $OldFolder)) {
                Remove-Item -Recurse -Force $OldFolder
                Write-LogSuccess "Removed stale source folder: $OldFolder"
                $Parent = Split-Path $Old
                while ($Parent) {
                    $ParentFolder = Join-Path $TargetDir $Parent
                    if (@(Get-ChildItem -Force $ParentFolder).Count -gt 0) { break }
                    Remove-Item -Force $ParentFolder
                    $Parent = Split-Path $Parent
                }
            }
        }
    }
    $ManifestText = if ($CurrentDests.Count -gt 0) { ($CurrentDests -join "`n") + "`n" } else { "" }
    Set-Content -Path $ManifestFile -Value $ManifestText -NoNewline
} finally {
    if (Test-Path $StagingRoot) {
        Remove-Item -Recurse -Force $StagingRoot
    }
}

if ($global:Errors -gt 0) {
    Write-LogError "Sync completed with $($global:Errors) error(s) and $($global:Warnings) warning(s)."
    exit 1
} elseif ($global:Warnings -gt 0) {
    Write-LogWarning "Sync completed with $($global:Warnings) warning(s)."
} else {
    Write-LogSuccess "Sync completed successfully!"
}
