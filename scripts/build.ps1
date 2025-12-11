#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds the database containerizer Docker image and optionally extracts
    the generated /artifacts directory from the resulting image.

.DESCRIPTION
    This script acts as a wrapper around `docker build`, supplying all required
    and optional build arguments used by the Database Containerizer pipeline.
    It supports:

      - Configuring NuGet feeds and authentication
      - Passing EF Core Power Tools configuration (file or URL)
      - Selecting a database backup from URL or local backup folder
      - Setting build metadata such as VERSION and IMAGE_REPOSITORY
      - Using a specific database name for all generated artifacts
      - Extracting the generated `/artifacts` directory after build

    It is functionally equivalent to `scripts/build.sh` and is intended for 
    users working in Windows or PowerShell environments.

.PARAMETER NugetFeeds
    Semicolon-separated list of NuGet feeds. Supports "name=url" or "url".

.PARAMETER NugetAuth
    Semicolon-separated name=PAT token pairs. Feed names must match `NugetFeeds`.

.PARAMETER UseInsecureSsl
    yes|no – Controls curl/apt SSL verification for internal networks.

.PARAMETER Version
    Product/database version applied to DACPAC, SQL project, and NuGet package.

.PARAMETER SaPassword
    SQL Server SA password. Used if no BuildKit secret is supplied.

.PARAMETER ImageRepository
    Metadata only, included in the output manifest.

.PARAMETER EfcptConfigUrl
    URL to a custom EF Core Power Tools configuration file.

.PARAMETER EfcptConfigFile
    Path (inside build context) to a custom configuration file.

.PARAMETER DatabaseBackupUrl
    URL to a .bak file. Used when no local file is provided.

.PARAMETER DatabaseBackupFile
    Local filename inside `/backup` directory to restore from.

.PARAMETER DatabaseName
    Logical database name used for restore, DACPAC, and EF model generation.

.PARAMETER Tag
    Docker image tag to produce.

.PARAMETER Context
    Build context folder. Defaults to repository root.

.PARAMETER ExtractTo
    Directory where artifacts will be extracted. Defaults to ./artifacts.

.PARAMETER NoExtractArtifacts
    When set, skips extracting `/artifacts` from the built image.

.EXAMPLE
    # Basic usage with direct password and local .bak file
    ./build.ps1 `
        -DatabaseName MyDB `
        -DatabaseBackupFile mydb.bak `
        -Version 1.0.0 `
        -NugetFeeds "Internal=https://feed" `
        -NugetAuth "Internal=PATVALUE" `
        -Tag mydb

.EXAMPLE
    # Passing SA password securely using SecureString
    $secure = Read-Host "Enter SA password" -AsSecureString

    ./build.ps1 `
        -DatabaseName MyDB `
        -DatabaseBackupUrl "https://example.com/db.bak" `
        -Version 2.0.0 `
        -SaPassword $secure `
        -NugetFeeds "Internal=https://feed" `
        -NugetAuth "Internal=PATVALUE" `
        -Tag mydb-secure

#>
[CmdletBinding()]
param(
    # Semicolon-separated NuGet feeds (name=url or url)
    [string] $NugetFeeds = "",

    # Semicolon-separated name=PAT pairs
    [string] $NugetAuth = "",

    # yes|no - controls apt/curl SSL validation in the image
    [string] $UseInsecureSsl = "no",

    # Product/database artifact version
    [string] $Version = "1.0.0",

    # SA password for SQL Server (SecureString; optional)
    [SecureString] $SaPassword,

    # Metadata only, not used by SQL Server itself
    [string] $ImageRepository = "local/database-containerizer",

    # URL to efcpt-config.json (optional)
    [string] $EfcptConfigUrl = "",

    # Path inside build context to copy as efcpt-config.json (optional)
    [string] $EfcptConfigFile = "",

    # URL to database .bak (optional)
    [string] $DatabaseBackupUrl = "",

    # Local .bak filename inside /backup/ (optional)
    [string] $DatabaseBackupFile = "",

    # Database name
    [string] $DatabaseName = "MyDB",

    # Docker image tag
    [string] $Tag = "mydb",

    # Docker build context
    [string] $Context = "",

    # Output extraction directory override
    [string] $ExtractTo = "",

    # Skip extracting /artifacts
    [switch] $NoExtractArtifacts
)

$ErrorActionPreference = 'Stop'

# Resolve root dir
$ScriptDir = Split-Path -Path $PSCommandPath -Parent
$RootDir   = Split-Path -Path $ScriptDir -Parent

if ([string]::IsNullOrWhiteSpace($Context)) {
    $Context = $RootDir
}

# If ExtractTo not provided, default to $RootDir/artifacts
if ([string]::IsNullOrWhiteSpace($ExtractTo)) {
    $ExtractTo = Join-Path $RootDir "artifacts"
}

# Resolve SA password to plain text for docker build
if ($PSBoundParameters.ContainsKey('SaPassword') -and $SaPassword) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $plainSaPassword = [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}
else {
    # Fallback default (for local/dev only – prefer BuildKit secrets in real use)
    $plainSaPassword = "YourStrong!P@ssw0rd"
}

Write-Host "Building image '$Tag' using context '$Context'..." -ForegroundColor Cyan
Write-Host "  DATABASE_NAME        = $DatabaseName"
Write-Host "  VERSION              = $Version"
Write-Host "  NUGET_FEEDS          = $NugetFeeds"
Write-Host "  NUGET_AUTH           = $NugetAuth"
Write-Host "  USE_INSECURE_SSL     = $UseInsecureSsl"
Write-Host "  DATABASE_BACKUP_URL  = $DatabaseBackupUrl"
Write-Host "  DATABASE_BACKUP_FILE = $DatabaseBackupFile"
Write-Host "  EFCPT_CONFIG_URL     = $EfcptConfigUrl"
Write-Host "  EFCPT_CONFIG_FILE    = $EfcptConfigFile"
Write-Host "  ARTIFACT EXTRACT TO  = $ExtractTo"
Write-Host ""

# Build docker build arguments
$buildArgs = @(
    "--progress=plain"

    "--build-arg", "nuget_feeds=$NugetFeeds"
    "--build-arg", "nuget_auth=$NugetAuth"
    "--build-arg", "USE_INSECURE_SSL=$UseInsecureSsl"
    "--build-arg", "VERSION=$Version"
    "--build-arg", "SA_PASSWORD=$plainSaPassword"
    "--build-arg", "IMAGE_REPOSITORY=$ImageRepository"
    "--build-arg", "efcpt_config_url=$EfcptConfigUrl"
    "--build-arg", "efcpt_config_file=$EfcptConfigFile"
    "--build-arg", "DATABASE_BACKUP_URL=$DatabaseBackupUrl"
    "--build-arg", "DATABASE_BACKUP_FILE=$DatabaseBackupFile"
    "--build-arg", "DATABASE_NAME=$DatabaseName"
    "-t", $Tag
    $Context
)

Write-Host "Running: docker build $($buildArgs -join ' ')" -ForegroundColor DarkGray
docker build @buildArgs

if (-not $NoExtractArtifacts) {
    $tmpContainer = "$Tag-tmp-$PID"

    Write-Host "Creating temp container '$tmpContainer' to extract /artifacts..." -ForegroundColor Cyan
    docker create --name $tmpContainer $Tag | Out-Null

    if (-not (Test-Path $ExtractTo)) {
        Write-Host "Creating extraction directory '$ExtractTo'..."
        New-Item -ItemType Directory -Path $ExtractTo -Force | Out-Null
    }

    Write-Host "Copying container /artifacts → $ExtractTo" -ForegroundColor Cyan
    docker cp "${tmpContainer}:/artifacts/." $ExtractTo

    Write-Host "Removing temp container '$tmpContainer'..." -ForegroundColor Cyan
    docker rm $tmpContainer | Out-Null

    Write-Host "Artifacts extracted to: $ExtractTo" -ForegroundColor Green
}
else {
    Write-Host "Skipping artifact extraction (--NoExtractArtifacts)." -ForegroundColor Yellow
}

Write-Host "Build complete." -ForegroundColor Green

