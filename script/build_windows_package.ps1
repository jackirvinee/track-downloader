[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string] $Version = "0.1.0.0",

    [ValidateSet("x64")]
    [string] $Architecture = "x64",

    [string] $Publisher = "CN=Track Downloader Development",

    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $SigningCertificateThumbprint,

    [Uri] $TimestampUrl,

    [string] $OutputDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$projectPath = Join-Path $repositoryRoot "windows\TrackDownloader.Windows\TrackDownloader.Windows.csproj"
$packageSource = Join-Path $repositoryRoot "windows\TrackDownloader.Windows.Package"
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repositoryRoot "artifacts\windows"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Find-WindowsSdkTool([string] $Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path $kitsRoot) {
        $candidate = Get-ChildItem -Path $kitsRoot -Directory |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "$Architecture\$Name" } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if ($candidate) {
            return $candidate
        }
    }

    throw "$Name was not found. Install the Windows SDK packaging tools."
}

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("track-downloader-msix-" + [Guid]::NewGuid().ToString("N"))
$payloadRoot = Join-Path $workRoot "payload"
$packagePath = Join-Path $OutputDirectory "Track-Downloader-$Version-$Architecture.msix"

try {
    New-Item -ItemType Directory -Path $payloadRoot | Out-Null
    dotnet publish $projectPath --configuration Release --runtime "win-$Architecture" --self-contained true --output $payloadRoot -p:PublishSingleFile=false
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }

    Copy-Item (Join-Path $packageSource "Assets") $payloadRoot -Recurse
    $manifestPath = Join-Path $payloadRoot "AppxManifest.xml"
    Copy-Item (Join-Path $packageSource "AppxManifest.xml") $manifestPath

    [xml] $manifest = Get-Content -LiteralPath $manifestPath
    $identity = $manifest.Package.Identity
    $identity.Version = $Version
    $identity.ProcessorArchitecture = $Architecture

    if ($SigningCertificateThumbprint) {
        if (-not $TimestampUrl -or $TimestampUrl.Scheme -ne "https") {
            throw "A trusted HTTPS TimestampUrl is required for signed packages."
        }
        $certificate = Get-Item "Cert:\CurrentUser\My\$SigningCertificateThumbprint" -ErrorAction Stop
        if ($PSBoundParameters.ContainsKey("Publisher") -and $Publisher -ne $certificate.Subject) {
            throw "Publisher must exactly match the signing certificate subject."
        }
        $Publisher = $certificate.Subject
    }
    $identity.Publisher = $Publisher

    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($manifestPath, $settings)
    try {
        $manifest.Save($writer)
    }
    finally {
        $writer.Dispose()
    }

    $makeAppx = Find-WindowsSdkTool "MakeAppx.exe"
    & $makeAppx pack /v /o /h SHA256 /d $payloadRoot /p $packagePath
    if ($LASTEXITCODE -ne 0) {
        throw "MakeAppx.exe failed with exit code $LASTEXITCODE."
    }

    if ($SigningCertificateThumbprint) {
        $signTool = Find-WindowsSdkTool "SignTool.exe"
        & $signTool sign /sha1 $SigningCertificateThumbprint /fd SHA256 /tr $TimestampUrl.AbsoluteUri /td SHA256 $packagePath
        if ($LASTEXITCODE -ne 0) {
            throw "SignTool.exe failed with exit code $LASTEXITCODE."
        }
        & $signTool verify /pa /v $packagePath
        if ($LASTEXITCODE -ne 0) {
            throw "The signed package failed SignTool verification."
        }
        Write-Output "Signed package built and verified: $packagePath"
    }
    else {
        Write-Output "Unsigned package built: $packagePath"
        Write-Output "Signing, installation, and clean-device proof are not complete."
    }
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
