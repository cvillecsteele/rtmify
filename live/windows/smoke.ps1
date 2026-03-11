$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$server = Join-Path $root "rtmify-live.exe"
if (-not (Test-Path $server)) {
    throw "rtmify-live.exe not found beside smoke.ps1"
}

$port = 8000
$tempRoot = Join-Path $env:TEMP "rtmify-live-smoke"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$dbPath = Join-Path $tempRoot "graph.db"

$proc = Start-Process -FilePath $server -ArgumentList @("--db", $dbPath, "--port", "$port", "--no-browser") -PassThru -WorkingDirectory $root
try {
    $deadline = (Get-Date).AddSeconds(15)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-RestMethod -Uri "http://localhost:$port/api/status" -TimeoutSec 2
            if ($null -ne $resp.configured) {
                $ready = $true
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }

    if (-not $ready) {
        throw "rtmify-live.exe did not become ready on port $port"
    }

    if (-not (Test-Path $dbPath)) {
        throw "Expected DB not created at $dbPath"
    }
} finally {
    if ($null -ne $proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
        $proc.WaitForExit()
    }
}
