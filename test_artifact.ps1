# Test whisper.cpp install tree artifact
# Usage: .\test_artifact.ps1 [--download] [<artifact.tar.gz>]
#
# Examples:
#   .\test_artifact.ps1 whisper_install-windows-x86_64.tar.gz       (verify local file)
#   .\test_artifact.ps1 --download                                    (download latest release + verify)

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
# Download mode: use latest GitHub Release to find artifacts
# Releases are created automatically by the workflow for each build.
# No token needed for public repo releases. For private repos, set GH_TOKEN.
# ---------------------------------------------------------------------------
if ($fileArg -eq "__DOWNLOAD_LATEST__") {
    Write-Host "=== Downloading whisper artifact from latest release ===" -ForegroundColor Cyan

    # Get latest release tag (no auth needed for public repos)
    try {
        $headers = @{}
        if ($env:GH_TOKEN) {
            $headers["Authorization"] = "token $env:GH_TOKEN"
        }
        
        $response = Invoke-RestMethod -Uri "https://api.github.com/repos/lanly-dev/whisper-build/releases/latest" `
            -Headers $headers -ErrorAction Stop
        
        $releaseTag = $response.tag_name
        Write-Host "  Latest release: $releaseTag" -ForegroundColor Green
    } catch {
        Write-Host "  [ERROR] Failed to fetch latest release." -ForegroundColor Red
        if ($env:GH_TOKEN) {
            Write-Host "  Check token permissions or use a valid token." -ForegroundColor Yellow
        } else {
            Write-Host "  Set GH_TOKEN for private repos:" -ForegroundColor Yellow
            Write-Host "  `$env:GH_TOKEN='your_token'" -ForegroundColor Cyan
        }
        exit 1
    }

    # List available artifacts in this release
    $artifacts = $response.assets | Where-Object { $_.name -like 'whisper_install*' } | ForEach-Object { $_.name }
    
    if (-not $artifacts) {
        Write-Host "  [ERROR] No whisper_install artifacts found in release $releaseTag." -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "  Available artifacts:" -ForegroundColor White
    foreach ($art in $artifacts) {
        Write-Host "    - $art" -ForegroundColor Gray
    }
    Write-Host ""

    # Platform detection for Windows is straightforward
    $artifactName = "whisper_install-windows-x86_64.tar.gz"
    
    Write-Host "  Downloading $artifactName to $(Get-Location) ..." -ForegroundColor Cyan
    try {
        $downloadUrl = "https://github.com/lanly-dev/whisper-build/releases/download/${releaseTag}/${artifactName}"
        Invoke-WebRequest -Uri $downloadUrl -OutFile ".\$artifactName" -ErrorAction Stop
        Write-Host "  Downloaded: .\$artifactName" -ForegroundColor Green
    } catch {
        Write-Host "  [ERROR] Failed to download artifact." -ForegroundColor Red
        exit 1
    }
    
    $fileArg = ".\$artifactName"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Verify artifact structure
# ---------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($fileArg) -or -not (Test-Path $fileArg)) {
    Write-Host "Usage: .\test_artifact.ps1 [--download] [<artifact.tar.gz>]" -ForegroundColor Red
    Write-Host "" -ForegroundColor White
    Write-Host "  --download          Download latest artifact from GitHub Release (auto)" -ForegroundColor White
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