#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "==================== Database Containerizer CLI Tests ====================" -ForegroundColor Cyan
Write-Host ""

# --------------------------------------------------------------------------------------
# Helper: find repo root (where Dockerfile / solution lives)
# --------------------------------------------------------------------------------------
$ScriptDir = Split-Path -Path $PSCommandPath -Parent
$RepoRoot  = Split-Path -Path $ScriptDir -Parent

# Fallback: walk up till we see a Dockerfile or .sln/.slnx
if (-not (Test-Path (Join-Path $RepoRoot "Dockerfile"))) {
    $dir = $ScriptDir
    while ($true) {
        $hasDockerfile = Test-Path (Join-Path $dir "Dockerfile")
        $hasSln  = (Get-ChildItem -Path $dir -Filter '*.sln'  -ErrorAction Ignore | Measure-Object).Count -gt 0
        $hasSlnx = (Get-ChildItem -Path $dir -Filter '*.slnx' -ErrorAction Ignore | Measure-Object).Count -gt 0

        if ($hasDockerfile -or $hasSln -or $hasSlnx) {
            $RepoRoot = $dir
            break
        }

        $parent = Split-Path $dir -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or ($parent -eq $dir)) {
            throw "Unable to locate repository root (no Dockerfile or solution found)."
        }

        $dir = $parent
    }
}

$BuildScript = Join-Path $RepoRoot "scripts/build.ps1"
if (-not (Test-Path $BuildScript)) {
    throw "build.ps1 not found at $BuildScript"
}

$BackupDir = Join-Path $RepoRoot "backup"
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

# Default URL for test backup (AdventureWorks)
$DefaultTestBackupUrl = "https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak"

# --------------------------------------------------------------------------------------
# Helper: simple test wrapper
# --------------------------------------------------------------------------------------
$global:TestCount  = 0
$global:FailCount  = 0

function Invoke-Test {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [ScriptBlock] $Body
    )

    $global:TestCount++

    Write-Host ""
    Write-Host "==================== TEST $($global:TestCount): $Name ====================" -ForegroundColor Yellow

    try {
        & $Body
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        $global:FailCount++
        Write-Host "[FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --------------------------------------------------------------------------------------
# TEST 1: Build with defaults (minimal parameters)
# --------------------------------------------------------------------------------------
Invoke-Test "Build with defaults (minimal parameters)" {
    Write-Host "[INFO] Running build.ps1 with minimal parameters..." -ForegroundColor Cyan

    Push-Location $RepoRoot
    try {
        & $BuildScript `
            -DatabaseName "DefaultDb" `
            -DatabaseBackupUrl $DefaultTestBackupUrl `
            -Version "1.0.0" `
            -Tag "dbcontainerizer-test-defaults" `
            -UseInsecureSsl "yes" `
            -NoExtractArtifacts

        if ($LASTEXITCODE -ne 0) {
            throw "docker build failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

# --------------------------------------------------------------------------------------
# TEST 2: Build with local backup file (auto-download if missing)
# --------------------------------------------------------------------------------------
Invoke-Test "Build with local backup file" {
    $TestDbName          = $env:TEST_DB_NAME
    if ([string]::IsNullOrWhiteSpace($TestDbName)) {
        $TestDbName = "TestDb"
    }

    $TestLocalBackupFile = $env:TEST_LOCAL_BACKUP_FILE
    if ([string]::IsNullOrWhiteSpace($TestLocalBackupFile)) {
        $TestLocalBackupFile = "$TestDbName.bak"
    }

    $backupPath = Join-Path $BackupDir $TestLocalBackupFile

    if (-not (Test-Path $backupPath)) {
        $BackupUrl = $env:TEST_BACKUP_URL
        if ([string]::IsNullOrWhiteSpace($BackupUrl)) {
            $BackupUrl = $DefaultTestBackupUrl
        }

        Write-Host "[INFO] Local backup '$backupPath' not found. Downloading from $BackupUrl..." -ForegroundColor Cyan

        try {
            Invoke-WebRequest -Uri $BackupUrl -OutFile $backupPath
        }
        catch {
            throw "Failed to download test backup from $BackupUrl. $($_.Exception.Message)"
        }

        if (-not (Test-Path $backupPath)) {
            throw "Download appeared to succeed, but '$backupPath' still does not exist."
        }

        Write-Host "[INFO] Test backup downloaded to $backupPath" -ForegroundColor Green
    }
    else {
        Write-Host "[INFO] Using existing local backup: $backupPath" -ForegroundColor Cyan
    }

    Push-Location $RepoRoot
    try {
        & $BuildScript `
            -DatabaseName $TestDbName `
            -DatabaseBackupFile $TestLocalBackupFile `
            -Version "1.0.1" `
            -Tag "dbcontainerizer-test-local-backup" `
            -UseInsecureSsl "yes" `
            -NoExtractArtifacts

        if ($LASTEXITCODE -ne 0) {
            throw "docker build failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

# --------------------------------------------------------------------------------------
# TEST 3: Build with missing backup should fail
# --------------------------------------------------------------------------------------
Invoke-Test "Build with missing backup should fail" {
    Write-Host "[INFO] Running build.ps1 with missing backup file (expect failure)..." -ForegroundColor Cyan

    $MissingFile = "this_file_should_not_exist_$(Get-Random).bak"

    Push-Location $RepoRoot
    try {
        & $BuildScript `
            -DatabaseName "MissingDb" `
            -DatabaseBackupFile $MissingFile `
            -Version "1.0.2" `
            -Tag "dbcontainerizer-test-missing-backup" `
            -UseInsecureSsl "yes" `
            -NoExtractArtifacts

        if ($LASTEXITCODE -eq 0) {
            throw "Expected failure due to missing backup file, but build succeeded."
        }
        else {
            Write-Host "[INFO] Build failed as expected with exit code $LASTEXITCODE" -ForegroundColor Green
        }
    }
    finally {
        Pop-Location
    }
}

# --------------------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------------------
Write-Host ""
Write-Host "==================== SUMMARY ====================" -ForegroundColor Cyan
Write-Host "Total tests:  $TestCount"
Write-Host "Failed tests: $FailCount"

if ($FailCount -gt 0) {
    Write-Host "Some tests failed." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "All tests passed." -ForegroundColor Green
    exit 0
}

