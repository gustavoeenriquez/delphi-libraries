# Building Delphi Libraries Collection

This guide explains how to build all libraries in this collection.

## Prerequisites

### Minimum Requirements
- **Delphi 12 Athens** (Studio 23.0)
- **MSBuild** (included with Delphi)
- **Windows 10 or later** (for development)

### Installation

If Delphi is not installed:
1. Download from Embarcadero website
2. Install to default location: `C:\Program Files (x86)\Embarcadero\Studio\23.0`

## Building Individual Libraries

### MP3 Decoder

```bash
cd mp3-decoder
msbuild MP3ToWAV.dproj /p:Config=Release /p:Platform=Win64
```

**Output:** `mp3-decoder\Win64\Release\MP3ToWAV.exe`

#### Configuration Options

| Option | Values | Default |
|--------|--------|---------|
| Config | Debug, Release | Release |
| Platform | Win32, Win64, Linux64 | Win64 |

**Examples:**

```bash
# Debug build (slower, easier to debug)
msbuild MP3ToWAV.dproj /p:Config=Debug /p:Platform=Win64

# 32-bit build
msbuild MP3ToWAV.dproj /p:Config=Release /p:Platform=Win32

# Linux64 target (cross-compile from Windows)
msbuild MP3ToWAV.dproj /p:Config=Release /p:Platform=Linux64
```

#### Build Targets

| Target | Purpose |
|--------|---------|
| Build | Incremental build (default) |
| Rebuild | Clean build from scratch |
| Clean | Remove compiled files |

```bash
# Rebuild from scratch
msbuild MP3ToWAV.dproj /t:Rebuild /p:Config=Release /p:Platform=Win64

# Clean
msbuild MP3ToWAV.dproj /t:Clean /p:Config=Release /p:Platform=Win64
```

## Building All Libraries (Group Build)

### Option 1: Manual Script

Create a batch file `build-all.bat`:

```batch
@echo off
echo Building MP3 Decoder...
cd mp3-decoder
msbuild MP3ToWAV.dproj /p:Config=Release /p:Platform=Win64
if errorlevel 1 (
    echo FAILED: MP3 Decoder
    exit /b 1
)
cd ..

echo All libraries built successfully!
```

Run it:
```bash
build-all.bat
```

### Option 2: GitHub Actions (CI/CD)

Builds automatically on every push. See `.github/workflows/build.yml`

## Troubleshooting

### Error: "rsvars.bat not found"

**Cause:** Delphi environment variables not set.

**Solution:** Ensure Delphi is installed at:
```
C:\Program Files (x86)\Embarcadero\Studio\23.0
```

Or manually set environment:
```batch
set BDS=C:\Program Files (x86)\Embarcadero\Studio\23.0
```

### Error: "F2613: Unit 'X' not found"

**Cause:** Missing library paths for the platform.

**Solution:** 
1. Open Delphi IDE
2. Go to Tools → Options → Language → Delphi → Library
3. Select your platform (Win32/Win64/Linux64)
4. Add missing paths to "Library path"

### Error: "Incompatible compilation flags"

**Cause:** Project settings mismatch with IDE settings.

**Solution:**
1. Delete all `.dcu` files
2. Run: `msbuild ... /t:Clean`
3. Rebuild: `msbuild ... /t:Rebuild`

### Compilation Takes Too Long

**Optimization:** Enable parallel compilation

```bash
msbuild MP3ToWAV.dproj /m /p:Config=Release /p:Platform=Win64
```

`/m` = Use multiple processor cores (faster on multi-core systems)

## Output Locations

After building, compiled binaries go to:

```
mp3-decoder/
├── Win32/Release/MP3ToWAV.exe      (32-bit release)
├── Win64/Release/MP3ToWAV.exe      (64-bit release)
├── Win64/Debug/MP3ToWAV.exe        (64-bit debug)
└── Linux64/Release/MP3ToWAV        (Linux64 ELF binary)
```

## Testing After Build

### Quick Test

```bash
cd mp3-decoder
Win64\Release\MP3ToWAV.exe samples\file_7461.mp3 output.wav
```

Expected output:
```
Opening: samples\file_7461.mp3
MP3 format: 24000 Hz, 1 ch, 128 kbps
Decoded: 100 frames, 2.4 seconds
Done. Decoded 165 frames, 95040 samples (3.96 seconds)
Output written to: output.wav
```

### Verify Output

Check that `output.wav` is a valid WAV file:
- Size should be > 200 KB (for the test file)
- File header should start with "RIFF"
- Can be opened in any media player

## Advanced: Command Line Build Script

Create `build.ps1` (PowerShell):

```powershell
param(
    [string]$Config = "Release",
    [string]$Platform = "Win64"
)

$ErrorActionPreference = "Stop"

# Set Delphi environment
$env:BDS = "C:\Program Files (x86)\Embarcadero\Studio\23.0"
$env:PATH += ";$env:BDS\Bin"

# Build libraries
$libraries = @(
    "mp3-decoder"
)

foreach ($lib in $libraries) {
    Write-Host "Building $lib..." -ForegroundColor Cyan
    
    $project = "$lib\*.dproj" | Get-Item
    $output = msbuild $project.FullName `
        /p:Config=$Config `
        /p:Platform=$Platform `
        /v:minimal
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $lib" -ForegroundColor Red
        exit 1
    }
}

Write-Host "All libraries built successfully!" -ForegroundColor Green
```

Usage:
```bash
powershell -ExecutionPolicy Bypass -File build.ps1 -Config Release -Platform Win64
```

## CI/CD: GitHub Actions

Automatic builds on every push:

See `.github/workflows/build.yml` for configuration.

Status badges can be added to `README.md`:
```markdown
[![Build Status](https://github.com/your-username/delphi-libraries/actions/workflows/build.yml/badge.svg)](https://github.com/your-username/delphi-libraries/actions)
```

---

## Clean Build

To reset everything and rebuild from scratch:

```bash
# Remove all compiled files
msbuild mp3-decoder\MP3ToWAV.dproj /t:Clean /p:Config=Release /p:Platform=Win64

# Rebuild everything
msbuild mp3-decoder\MP3ToWAV.dproj /t:Rebuild /p:Config=Release /p:Platform=Win64
```

---

## Performance Tips

1. **Use Release build** (much faster than Debug)
2. **Parallel compilation** (`/m` flag)
3. **SSD storage** (faster I/O)
4. **Close IDE** while building (frees memory)
5. **Disable antivirus scanning** on build folders temporarily

---

Last Updated: 2026-04-02
