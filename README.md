# whisper.cpp GitHub Actions Build

This repository contains a GitHub Actions workflow to automatically build [whisper.cpp](https://github.com/ggerganov/whisper.cpp) on push and pull requests.

## What This Does

The CI workflow builds whisper.cpp on three platforms:
- **Ubuntu LTS** (GCC/Clang)
- **Windows** (Visual Studio 2022)
- **macOS** (Clang)

Built binaries are uploaded as GitHub Actions artifacts for each run.

## Usage

1. Clone this repository
2. Push to `main` or create a pull request
3. Check the "Actions" tab for build status
4. Download artifacts from the workflow run

## Local Build

To build whisper.cpp locally, clone and compile:

```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
mkdir build
cmake -B build
cmake --build build --config Release
```

## Workflow Configuration

The workflow runs on:
- Pushes to `main` or `master` branches
- Pull requests targeting `main` or `master`

See `.github/workflows/build.yml` for full configuration.