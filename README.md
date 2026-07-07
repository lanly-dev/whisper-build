# whisper.cpp GitHub Actions Build

This repository contains a GitHub Actions workflow to automatically build [whisper.cpp](https://github.com/ggml-org/whisper.cpp) on push, pull requests, and monthly schedules.

## What This Does

The CI workflow builds whisper.cpp from source on three platforms:
- **Ubuntu LTS** (GCC, CMake)
- **Windows** (MSYS2 Mingw-w64)
- **macOS** (Clang, Homebrew)

Each build packages the **full install tree** (`include/`, `lib/`, `pkgconfig/`) as a release artifact for use with projects like ffmpeg.

## Releases

Built artifacts are published as **GitHub Releases** with auto-incrementing tag format:

```
vYYYY.MM.DD-WHISPER_LAST3-GLOBAL_INCREMENT
```

Where:
- `YYYY.MM.DD` - Build date in UTC
- `WHISPER_LAST3` - Last 2 characters of whisper.cpp upstream commit hash
- `GLOBAL_INCREMENT` - Zero-padded 4-digit counter (increments per release)

Example tags: `v2026.07.08-ab1000`, `v2026.07.09-cd1001`

Download releases from the [Releases page](https://github.com/lanly-dev/whisper-build/releases).

## Artifacts

Each workflow run produces platform-specific install tree archives:
- `whisper_install-linux-x86_64.tar.gz`
- `whisper_install-darwin-universal.tar.gz`
- `whisper_install-windows-x86_64.tar.gz`

Download artifacts from the "Actions" tab → select a workflow run → scroll to "Artifacts".

## Triggering Builds

The workflow runs automatically on:
- Push to `main` or `master` branches
- Pull requests targeting `main` or `master`
- First day of every month at midnight UTC (monthly rebuild)

## Local Build

To build whisper.cpp locally, clone and compile:

```bash
git clone https://github.com/ggml-org/whisper.cpp.git
cd whisper.cpp
mkdir build
cmake -B build
cmake --build build --config Release
```

## Workflow Configuration

See [.github/workflows/build.yml](.github/workflows/build.yml) for the full workflow definition.