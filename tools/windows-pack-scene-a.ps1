param(
    [string]$Source = "$HOME\Desktop\WaifuX-Scene-Testset\A-basic-2947302287",
    [string]$SteamLibrary = "E:\SteamLibrary",
    [string]$Zip = "$HOME\Desktop\WaifuX-Scene-A-basic-2947302287.zip"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Source)) {
    throw "Tier A scene folder not found: $Source"
}

$WallpaperEngineRoot = Join-Path $SteamLibrary "steamapps\common\wallpaper_engine"
$AssetRoots = @(
    (Join-Path $WallpaperEngineRoot "assets-pc"),
    (Join-Path $WallpaperEngineRoot "assets")
) | Where-Object { Test-Path $_ }

if ($AssetRoots.Count -eq 0) {
    throw "Wallpaper Engine assets/assets-pc not found under: $WallpaperEngineRoot"
}

$RequiredHeaders = @(
    "common.h",
    "common_perspective.h",
    "common_blending.h",
    "common_composite.h",
    "common_blur.h",
    "common_fragment.h",
    "common_vertex.h",
    "common_fog.h",
    "common_foliage.h",
    "common_particles.h",
    "common_pbr.h",
    "common_pbr_2.h"
)

$StageRoot = Join-Path $env:TEMP ("WaifuX-Scene-A-Pack-" + [guid]::NewGuid().ToString("N"))
$SceneName = Split-Path $Source -Leaf
$StageScene = Join-Path $StageRoot $SceneName
$CoreAssets = Join-Path $StageScene "core-assets"
$CoreShaders = Join-Path $CoreAssets "shaders"

try {
    New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null
    Copy-Item -Recurse -Force $Source $StageScene
    New-Item -ItemType Directory -Force -Path $CoreShaders | Out-Null

    Write-Host "Collecting Wallpaper Engine core shader headers..." -ForegroundColor Cyan
    $Missing = @()

    foreach ($Header in $RequiredHeaders) {
        $Relative = Join-Path "shaders" $Header
        $Found = $null

        foreach ($Root in $AssetRoots) {
            $Candidate = Join-Path $Root $Relative
            if (Test-Path $Candidate) {
                $Found = $Candidate
                break
            }
        }

        if ($null -eq $Found) {
            $Missing += $Relative
            Write-Warning "Missing core shader header: $Relative"
            continue
        }

        Copy-Item -Force $Found (Join-Path $CoreShaders $Header)
        Write-Host "  + $Relative"
    }

    # Optional core model used by the Solid background object in Angled Waves.
    $OptionalRelative = "models\util\solidlayer.json"
    foreach ($Root in $AssetRoots) {
        $Candidate = Join-Path $Root $OptionalRelative
        if (Test-Path $Candidate) {
            $Target = Join-Path $CoreAssets $OptionalRelative
            New-Item -ItemType Directory -Force -Path (Split-Path $Target -Parent) | Out-Null
            Copy-Item -Force $Candidate $Target
            Write-Host "  + $OptionalRelative"
            break
        }
    }

    if ($Missing.Count -gt 0) {
        Write-Warning ("Some headers were not found. Full-effect rendering may still fail: " + ($Missing -join ", "))
    }

    if (Test-Path $Zip) {
        Remove-Item -Force $Zip
    }

    Write-Host ""
    Write-Host "Packing Tier A scene + minimal core assets for Intel Mac testing..." -ForegroundColor Cyan

    # Prefer Windows bsdtar over Compress-Archive. Compress-Archive stores
    # Windows-style backslash paths and can result in unusable directory mode
    # metadata when macOS Archive Utility/unzip extracts the archive.
    $Tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($null -ne $Tar) {
        & $Tar.Source -a -c -f $Zip -C $StageRoot $SceneName
        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe failed to create ZIP (exit code $LASTEXITCODE)"
        }
    }
    else {
        Write-Warning "tar.exe not found; falling back to Compress-Archive. On macOS you may need to normalize extracted permissions."
        Compress-Archive -Path $StageScene -DestinationPath $Zip -CompressionLevel Optimal
    }

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    Write-Host "Transfer this file to the Intel Mac:"
    Write-Host "  $Zip"
    Write-Host ""
    Write-Host "The ZIP contains only the test scene plus the core shader headers needed by effects."
}
finally {
    if (Test-Path $StageRoot) {
        Remove-Item -Recurse -Force $StageRoot
    }
}
