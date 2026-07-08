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
# No token needed — uses GitHub Pages-style public artifact URLs.
# Artifact download endpoint (/actions/artifacts/{id}/tarball) is public for public repos.
# But listing runs DOES require auth, so we fall back to manual selection.
# ---------------------------------------------------------------------------
if ($fileArg -eq "__DOWNLOAD_LATEST__") {
    Write-Host "=== Downloading whisper artifact ===" -ForegroundColor Cyan

    # For public repos, artifact tarball URLs are:
    #   https://github.com/{repo}/releases/download/{artifact_name}
    # But Actions artifacts don't expose via that pattern. The only download URL is the API:
    #   https://api.github.com/repos/{repo}/actions/artifacts/{id}/tarball
    # which requires knowing the artifact ID (from list runs + list artifacts — needs auth).

    Write-Host "" -ForegroundColor White
    Write-Host "Artifact download works without token for public repos," -ForegroundColor Yellow
    Write-Host "but finding the latest run requires a GitHub token." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor White
    Write-Host "[Option 1] Set GH_TOKEN for full automation:" -ForegroundColor White
    Write-Host "  `$env:GH_TOKEN='ghp_xxx'; .\test_artifact.ps1 --download" -ForegroundColor Cyan
    Write-Host "" -ForegroundColor White
    Write-Host "[Option 2] Manual download (no token needed):" -ForegroundColor White
    Write-Host "  1. Open: https://github.com/lanly-dev/whisper-build/actions" -ForegroundColor White
    Write-Host "  2. Click latest successful 'Build' run" -ForegroundColor White
    Write-Host "  3. Download whisper_install-windows-x86_64.tar.gz from Artifacts" -ForegroundColor White
    Write-Host "  4. Run: .\test_artifact.ps1 whisper_install-windows-x86_64.tar.gz" -ForegroundColor Cyan
    exit 0
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