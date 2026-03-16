$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $root "../..")
$server = Join-Path $repoRoot "zig-out/bin/rtmify-live.exe"
if (-not (Test-Path $server)) {
    throw "rtmify-live.exe not found at $server"
}

$port = 8000
$tempRoot = Join-Path $env:TEMP "rtmify-live-smoke"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$dbPath = Join-Path $tempRoot "graph.db"

$stdoutLog = Join-Path $tempRoot "server-stdout.txt"
$stderrLog = Join-Path $tempRoot "server-stderr.txt"

$proc = Start-Process -FilePath $server -ArgumentList @("--db", $dbPath, "--port", "$port", "--no-browser") -PassThru -WorkingDirectory $root -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
try {
    $deadline = (Get-Date).AddSeconds(15)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            Write-Host "=== server exited early (exit code $($proc.ExitCode)) ==="
            Write-Host "=== server stdout ==="
            if (Test-Path $stdoutLog) { Get-Content $stdoutLog } else { Write-Host "(empty)" }
            Write-Host "=== server stderr ==="
            if (Test-Path $stderrLog) { Get-Content $stderrLog } else { Write-Host "(empty)" }
            throw "rtmify-live.exe exited with code $($proc.ExitCode) before becoming ready"
        }
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/status" -TimeoutSec 2
            if ($null -ne $resp.configured) {
                $ready = $true
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }

    if (-not $ready) {
        Write-Host "=== server stdout ==="
        if (Test-Path $stdoutLog) { Get-Content $stdoutLog } else { Write-Host "(empty)" }
        Write-Host "=== server stderr ==="
        if (Test-Path $stderrLog) { Get-Content $stderrLog } else { Write-Host "(empty)" }
        throw "rtmify-live.exe did not become ready on port $port"
    }
} finally {
    if ($null -ne $proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
        $proc.WaitForExit()
    }
}
