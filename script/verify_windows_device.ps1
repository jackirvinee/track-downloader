[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackagePath,

    [Parameter(Mandatory = $true)]
    [Uri] $AuthorizedMediaUrl
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($AuthorizedMediaUrl.Scheme -ne "https" -or $AuthorizedMediaUrl.Host.ToLowerInvariant() -notin @(
    "youtube.com",
    "www.youtube.com",
    "music.youtube.com",
    "youtu.be",
    "soundcloud.com",
    "www.soundcloud.com"
)) {
    throw "AuthorizedMediaUrl must be a supported HTTPS YouTube or SoundCloud URL."
}

$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
if ([System.IO.Path]::GetExtension($PackagePath) -ne ".msix") {
    throw "PackagePath must identify an MSIX package."
}

function Find-WindowsSdkTool([string] $Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path $kitsRoot) {
        $candidate = Get-ChildItem -Path $kitsRoot -Directory |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "x64\$Name" } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if ($candidate) {
            return $candidate
        }
    }

    throw "$Name was not found. Install the Windows SDK signing tools."
}

$signTool = Find-WindowsSdkTool "SignTool.exe"
& $signTool verify /pa /v $PackagePath
if ($LASTEXITCODE -ne 0) {
    throw "The package does not have a trusted, valid application signature."
}

$dependencies = @{}
foreach ($name in @("yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe")) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "$name is missing from PATH on this Windows device."
    }
    $dependencies[$name] = $command.Source
}

& $dependencies["deno.exe"] --version
if ($LASTEXITCODE -ne 0) {
    throw "deno.exe failed its device version check."
}

& $dependencies["yt-dlp.exe"] --simulate --no-playlist --js-runtimes deno --remote-components ejs:github -- $AuthorizedMediaUrl.AbsoluteUri
if ($LASTEXITCODE -ne 0) {
    throw "The live yt-dlp Deno/EJS probe failed on this Windows device."
}

Add-AppxPackage -Path $PackagePath -ForceApplicationShutdown
$installed = Get-AppxPackage -Name "com.jackirvine.trackdownloader" | Sort-Object Version -Descending | Select-Object -First 1
if (-not $installed) {
    throw "Windows did not report the Track Downloader package as installed."
}

Start-Process explorer.exe "shell:AppsFolder\$($installed.PackageFamilyName)!TrackDownloader"

[pscustomobject]@{
    Package = $PackagePath
    PackageVersion = $installed.Version.ToString()
    Signature = "trusted-and-verified"
    DenoEjsProbe = "passed"
    AppLaunch = "requested"
    OperatingSystem = [System.Environment]::OSVersion.VersionString
    VerifiedAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json

Write-Output "Device automation passed. Confirm the launched native UI and one authorized app download manually before marking device proof complete."
