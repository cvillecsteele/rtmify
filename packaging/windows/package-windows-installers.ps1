param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadZip,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Require-Path([string]$PathValue, [string]$Message) {
    if (-not (Test-Path -LiteralPath $PathValue)) {
        throw $Message
    }
}

function Load-InstallerInput([string]$ManifestPath, [string]$ExpectedVersion) {
    Require-Path $ManifestPath "Missing windows installer input manifest: $ManifestPath"
    $raw = Get-Content -LiteralPath $ManifestPath -Raw
    $data = $raw | ConvertFrom-Json
    if ($data.version -ne $ExpectedVersion) {
        throw "windows-installer-input.json version $($data.version) did not match workflow version $ExpectedVersion"
    }
    if (@($data.unsigned_installers).Count -ne 2) {
        throw "windows-installer-input.json must declare exactly 2 unsigned installers"
    }
    if (@($data.final_installers).Count -ne 2) {
        throw "windows-installer-input.json must declare exactly 2 final installers"
    }
    return $data
}

function Require-PayloadFiles([string]$PayloadDir) {
    $required = @(
        "rtmify-trace.exe",
        "RTMify Live.exe",
        "rtmify-live.exe",
        "windows-installer-input.json"
    )

    foreach ($name in $required) {
        $path = Join-Path $PayloadDir $name
        Require-Path $path "Missing payload file: $name"
    }
}

function Render-Template([string]$TemplatePath, [string]$DestinationPath, [hashtable]$Replacements) {
    Require-Path $TemplatePath "Missing template: $TemplatePath"
    $content = Get-Content -LiteralPath $TemplatePath -Raw
    foreach ($entry in $Replacements.GetEnumerator()) {
        $content = $content.Replace($entry.Key, $entry.Value)
    }
    Set-Content -LiteralPath $DestinationPath -Value $content -Encoding UTF8
}

function Find-InnoCompiler() {
    $preferred = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return $cmd.Source
    }

    throw "ISCC.exe not found after Chocolatey installation"
}

function Compile-InnoScript([string]$Compiler, [string]$ScriptPath) {
    & $Compiler "/Qp" $ScriptPath
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed for $ScriptPath"
    }
}

$workRoot = Join-Path $env:RUNNER_TEMP "rtmify-windows-installer-$Version"
$payloadDir = Join-Path $workRoot "payload"
$renderedDir = Join-Path $workRoot "rendered"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$outputDirPath = (Resolve-Path -LiteralPath $OutputDir).Path

if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -Recurse -Force -LiteralPath $workRoot
}
New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $renderedDir | Out-Null

Require-Path $PayloadZip "Missing payload zip: $PayloadZip"
Expand-Archive -LiteralPath $PayloadZip -DestinationPath $payloadDir -Force
Require-PayloadFiles $payloadDir

$installerInput = Load-InstallerInput (Join-Path $payloadDir "windows-installer-input.json") $Version

$sourceDir = $payloadDir.Replace('\', '\\')
$outputDirEscaped = $outputDirPath.Replace('\', '\\')

$traceTemplate = Join-Path $PSScriptRoot "trace-installer.iss.in"
$liveTemplate = Join-Path $PSScriptRoot "live-installer.iss.in"
$traceScript = Join-Path $renderedDir "trace-installer.iss"
$liveScript = Join-Path $renderedDir "live-installer.iss"

$common = @{
    "{{VERSION}}" = $Version
    "{{SOURCE_DIR}}" = $sourceDir
    "{{OUTPUT_DIR}}" = $outputDirEscaped
}

Render-Template $traceTemplate $traceScript $common
Render-Template $liveTemplate $liveScript $common

$compiler = Find-InnoCompiler
Compile-InnoScript $compiler $traceScript
Compile-InnoScript $compiler $liveScript

$expectedUnsigned = @(
    (Join-Path $outputDirPath $installerInput.unsigned_installers[0]),
    (Join-Path $outputDirPath $installerInput.unsigned_installers[1])
)

foreach ($path in $expectedUnsigned) {
    Require-Path $path "Missing unsigned installer output: $path"
}

$unexpected = Get-ChildItem -LiteralPath $outputDirPath -Filter *.exe -File |
    Where-Object { $_.Name -notin $installerInput.unsigned_installers }
if ($unexpected.Count -gt 0) {
    $names = ($unexpected | Select-Object -ExpandProperty Name) -join ", "
    throw "Unexpected unsigned installer outputs: $names"
}

Write-Host "Unsigned installers ready in $outputDirPath"
