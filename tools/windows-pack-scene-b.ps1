param(
    [string]$SteamLibrary = "E:\SteamLibrary",
    [string]$Source = "$HOME\Desktop\WaifuX-Scene-Testset\B-audio-effects-3034129787",
    [string]$Zip = "$HOME\Desktop\WaifuX-Scene-B-audio-effects-3034129787.zip"
)

$ErrorActionPreference = "Stop"

$WorkshopRoot = Join-Path $SteamLibrary "steamapps\workshop\content\431960"
$WallpaperEngineRoot = Join-Path $SteamLibrary "steamapps\common\wallpaper_engine"

if (-not (Test-Path $Source)) {
    $Fallback = Join-Path $WorkshopRoot "3034129787"
    if (Test-Path $Fallback) {
        $Source = $Fallback
    }
    else {
        throw "Tier B scene not found. Tried: $Source and $Fallback"
    }
}

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

$SceneName = "B-audio-effects-3034129787"
$StageRoot = Join-Path $env:TEMP ("WaifuX-Scene-B-Pack-" + [guid]::NewGuid().ToString("N"))
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

    # A few common utility resources are referenced by many Workshop scenes.
    $OptionalResources = @(
        "models\util\solidlayer.json",
        "materials\util\solidlayer.json"
    )

    foreach ($Relative in $OptionalResources) {
        foreach ($Root in $AssetRoots) {
            $Candidate = Join-Path $Root $Relative
            if (Test-Path $Candidate) {
                $Target = Join-Path $CoreAssets $Relative
                New-Item -ItemType Directory -Force -Path (Split-Path $Target -Parent) | Out-Null
                Copy-Item -Force $Candidate $Target
                Write-Host "  + $Relative"
                break
            }
        }
    }

    if ($Missing.Count -gt 0) {
        Write-Warning ("Some core shader headers were not found: " + ($Missing -join ", "))
    }

    if (Test-Path $Zip) {
        Remove-Item -Force $Zip
    }

    Write-Host ""
    Write-Host "Packing Tier B audio-responsive scene + minimal core assets..." -ForegroundColor Cyan

    $Tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($null -ne $Tar) {
        & $Tar.Source -a -c -f $Zip -C $StageRoot $SceneName
        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe failed to create ZIP (exit code $LASTEXITCODE)"
        }
    }
    else {
        Write-Warning "tar.exe not found; falling back to Compress-Archive. macOS permissions may need normalization after extraction."
        Compress-Archive -Path $StageScene -DestinationPath $Zip -CompressionLevel Optimal
    }

    $SizeMB = [math]::Round((Get-Item $Zip).Length / 1MB, 2)
    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    Write-Host "ZIP: $Zip"
    Write-Host "Size: $SizeMB MB"
    Write-Host "Transfer this ZIP to the Intel Mac Desktop."
}
finally {
    if (Test-Path $StageRoot) {
        Remove-Item -Recurse -Force $StageRoot
    }
}
