# Test whisper.cpp install tree artifact
# Usage: .\test_artifact.ps1 [--download] <artifact.tar.gz>
#
# Examples:
#   .\test_artifact.ps1 whisper_install-windows-x86_64.tar.gz       (verify local file)
#   .\test_artifact.ps1 --download                                    (always download latest + verify)

$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------------------
# Argument parsing: --download triggers download mode, or plain file path
# ---------------------------------------------------------------------------
$fileArg = ""

foreach ($arg in $args) {
    if ($arg -eq "--download") {
        $fileArg = "__DOWNLOAD_LATEST__"
    } else {
        $fileArg = $arg
    }
}

# ---------------------------------------------------------------------------
# Download mode: always use latest successful workflow run
# ---------------------------------------------------------------------------
if ($fileArg -eq "__DOWNLOAD_LATEST__") {
    Write-Host "=== Downloading latest whisper artifact ===" -ForegroundColor Cyan

    # Require gh CLI auth
    $ghToken = $env:GH_TOKEN
    if ([string]::IsNullOrEmpty($ghToken)) {
        Write-Host "[INFO] GH_TOKEN not set, using gh CLI auth..." -ForegroundColor Yellow
        $authCheck = & gh auth status 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] GitHub CLI not authenticated. Run: gh auth login" -ForegroundColor Red
            exit 1
        }
    }

    $repo = "lanly-dev/whisper-build"

    # Always find latest successful run
    Write-Host "[INFO] Finding latest successful run..." -ForegroundColor Yellow
    $output = & gh run list --repo $repo --branch main --status success --limit 5 --json databaseId 2>&1 | Out-String
    $match = [regex]::Matches($output, '"databaseId":(\d+)')
    if ($match.Count -eq 0) {
        Write-Host "[ERROR] No successful runs found" -ForegroundColor Red
        exit 1
    }
    $runId = $match[0].Groups[1].Value
    Write-Host "Latest run ID: $runId" -ForegroundColor Green

    # Get artifacts for this run
    $artifactsJson = & gh api "repos/$repo/actions/runs/$runId/artifacts" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to fetch artifacts for run $runId" -ForegroundColor Red
        exit 1
    }

    $artifacts = ($artifactsJson | ConvertFrom-Json).artifacts
    if (-not $artifacts) {
        Write-Host "[ERROR] No artifacts found" -ForegroundColor Red
        exit 1
    }

    # Automatically pick first whisper_install artifact (no prompt)
    $artifact = $artifacts | Where-Object { $_.name -like "whisper_install*" } | Select-Object -First 1
    if (-not $artifact) {
        Write-Host "[ERROR] No whisper_install artifact found in run $runId" -ForegroundColor Red
        Write-Host "Available artifacts:" -ForegroundColor Yellow
        foreach ($a in $artifacts) {
            Write-Host "  $($a.name)" -ForegroundColor White
        }
        exit 1
    }

    Write-Host "Found artifact: $($artifact.name)" -ForegroundColor Green
    Write-Host "Downloading..." -ForegroundColor Cyan

    $downloadDir = Join-Path $env:TEMP "whisper-test-$([guid]::NewGuid().ToString().Substring(0,8))"
    New-Item -ItemType Directory -Path $downloadDir | Out-Null

    # Download via GitHub API (tarball format)
    $dlUrl = "https://api.github.com/repos/$repo/actions/artifacts/$($artifact.id)/tarball"
    $authHeader = if ($ghToken) { "token $ghToken" } else { "" }

    $outputFile = Join-Path $downloadDir "$($artifact.name).tar.gz"
    $curlArgs = @("-L", "--fail", "-o", "`"$outputFile`"", "-H", "`"Authorization: $($authHeader)`"", "`"$dlUrl`"")

    & curl $curlArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] curl download failed, trying Invoke-WebRequest fallback..." -ForegroundColor Yellow
        try {
            Invoke-WebRequest -Uri $dlUrl -Headers @{ Authorization = "Bearer $($ghToken)" } -OutFile $outputFile -UseBasicParsing | Out-Null
        } catch {
            Write-Host "[ERROR] Download failed: $_" -ForegroundColor Red
            Remove-Item -Recurse -Force $downloadDir -ErrorAction SilentlyContinue
            exit 1
        }
    }

    $fileSize = ((Get-Item $outputFile).Length / 1MB)
    Write-Host "[OK] Downloaded to: $outputFile ($($fileSize.ToString('F2')) MB)" -ForegroundColor Green
    Write-Host ""

    # Use the downloaded file for verification
    $fileArg = $outputFile
}

# ---------------------------------------------------------------------------
# Verify artifact structure
# ---------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($fileArg) -or -not (Test-Path $fileArg)) {
    Write-Host "Usage: .\test_artifact.ps1 [--download] <artifact.tar.gz>" -ForegroundColor Red
    Write-Host "" -ForegroundColor White
    Write-Host "  --download          Download latest artifact from GitHub Actions (auto)" -ForegroundColor White
    Write-Host "  <file>              Verify a local artifact file" -ForegroundColor White
    exit 1
}

$TMPDIR = (New-Item -ItemType Directory -Name "whisper-test-$([guid]::NewGuid().ToString().Substring(0,8))" -Path ([System.IO.Path]::GetTempPath())).FullName

Write-Host ""
Write-Host "=== Extracting artifact ===" -ForegroundColor Cyan
tar xzf $fileArg -C $TMPDIR

Write-Host ""
Write-Host "=== Checking include/ ===" -ForegroundColor Cyan
if (Test-Path "$TMPDIR\whisper_target\include\whisper.h") {
    Write-Host "  [OK] whisper.h found" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] whisper.h not found!" -ForegroundColor Red
    Remove-Item -Recurse -Force $TMPDIR
    exit 1
}

Write-Host ""
Write-Host "=== Checking lib/ ===" -ForegroundColor Cyan
$libs = Get-ChildItem "$TMPDIR\whisper_target\lib\" -Filter "whisper*" -ErrorAction SilentlyContinue
if ($libs) {
    Write-Host "  [OK] Whisper library(s) found:" -ForegroundColor Green
    foreach ($lib in $libs) {
        Write-Host "      $($lib.Name) ($([math]::Round($lib.Length / 1KB, 1)) KB)" -ForegroundColor White
    }
} else {
    Write-Host "  [FAIL] No whisper library found!" -ForegroundColor Red
    Remove-Item -Recurse -Force $TMPDIR
    exit 1
}

Write-Host ""
Write-Host "=== Checking pkgconfig/ ===" -ForegroundColor Cyan
if (Test-Path "$TMPDIR\whisper_target\pkgconfig\whisper.pc") {
    Write-Host "  [OK] whisper.pc found" -ForegroundColor Green
} else {
    Write-Host "  [WARN] whisper.pc not found (optional)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Build test consumer project against the artifact
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Building test consumer ===" -ForegroundColor Cyan
$CONSUMER_DIR = Join-Path $TMPDIR "test-consumer"
New-Item -ItemType Directory -Path $CONSUMER_DIR | Out-Null
Set-Location $CONSUMER_DIR

@"
cmake_minimum_required(VERSION 3.16)
project(test_whisper C)
find_path(WHISPER_INCLUDE_DIR whisper.h PATHS "../whisper_target/include")
find_library(WHISPER_LIB whisper PATHS "../whisper_target/lib")
add_executable(main main.c)
target_include_directories(main PRIVATE `${WHISPER_INCLUDE_DIR})
target_link_libraries(main `${WHISPER_LIB})
"@ | Out-File -FilePath "CMakeLists.txt" -Encoding utf8

@"
#include <whisper.h>
#include <stdio.h>

int main(void) {
    const char* version = whisper_print_system_info();
    printf("whisper.cpp built on: %s\n", version);
    return 0;
}
"@ | Out-File -FilePath "main.c" -Encoding utf8

Write-Host "  Configuring CMake..." -ForegroundColor Cyan
$oldErr = $ErrorActionPreference
$ErrorActionPreference = "Continue"
cmake -B build -DCMAKE_PREFIX_PATH="$TMPDIR\whisper_target" 2>&1 | Out-String | Write-Host
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $oldErr

if ($exitCode -ne 0) {
    Remove-Item -Recurse -Force "build" -ErrorAction SilentlyContinue
    Write-Host "  [WARN] CMake find_path/lib failed, falling back to direct paths" -ForegroundColor Yellow

@"
cmake_minimum_required(VERSION 3.16)
project(test_whisper C)
add_executable(main main.c)
target_include_directories(main PRIVATE ../whisper_target/include)
target_link_libraries(main ../whisper_target/lib/libwhisper.a)
"@ | Out-File -FilePath "CMakeLists.txt" -Encoding utf8

    cmake -B build 2>&1 | Out-String | Write-Host
}

Write-Host "  Building..." -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
cmake --build build 2>&1 | Out-String | Write-Host
$buildExit = $LASTEXITCODE
$ErrorActionPreference = $oldErr

if ($buildExit -eq 0) {
    Write-Host "  [OK] Consumer built successfully!" -ForegroundColor Green
}

Write-Host ""
if ($buildExit -eq 0) {
    Write-Host "=== All checks passed ===" -ForegroundColor Green
} else {
    Write-Host "=== Build failed ===" -ForegroundColor Red
}

Set-Location $env:TEMP
Remove-Item -Recurse -Force $TMPDIR -ErrorAction SilentlyContinue