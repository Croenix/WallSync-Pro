# WallSync Server URL Publisher for Firebase Realtime Database
# Usage:
#   .\set_rtdb_url.ps1                           # Auto-detects local Wi-Fi / LAN IP
#   .\set_rtdb_url.ps1 "http://192.168.1.4:3000" # Explicit URL

param (
    [string]$CustomUrl = ""
)

$rtdbBase = "https://wallsync-e043c-default-rtdb.firebaseio.com"

# Determine target URL
if ([string]::IsNullOrWhiteSpace($CustomUrl)) {
    # Find active non-virtual IPv4
    $activeIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.IPAddress -notlike "127.*" -and
        $_.IPAddress -notlike "169.254.*" -and
        $_.IPAddress -notlike "192.168.56.*" -and
        $_.InterfaceAlias -notlike "*Virtual*" -and
        $_.InterfaceAlias -notlike "*vEthernet*" -and
        $_.InterfaceAlias -notlike "*Loopback*"
    } | Select-Object -First 1).IPAddress

    if ([string]::IsNullOrWhiteSpace($activeIp)) {
        $activeIp = "127.0.0.1"
    }

    $targetUrl = "http://" + $activeIp + ":3000"
} else {
    $targetUrl = $CustomUrl.Trim().TrimEnd('/')
    if ($targetUrl -notmatch '^https?://') {
        $targetUrl = "http://" + $targetUrl
    }
}

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  WallSync Firebase RTDB Server URL Publisher" -ForegroundColor Cyan
Write-Host "  Target URL:  $targetUrl" -ForegroundColor Yellow
Write-Host "  Database:    $rtdbBase" -ForegroundColor Gray
Write-Host "======================================================" -ForegroundColor Cyan

try {
    # 1. Update /serverUrl.json
    Write-Host "[1/3] Publishing to /serverUrl.json ..." -ForegroundColor Gray
    $rawUrlJson = '"' + $targetUrl + '"'
    Invoke-RestMethod -Uri ($rtdbBase + "/serverUrl.json") -Method Put -Body $rawUrlJson -ContentType "application/json" | Out-Null
    Write-Host "      [OK] /serverUrl.json updated!" -ForegroundColor Green

    # 2. Update /server.json
    Write-Host "[2/3] Publishing to /server.json ..." -ForegroundColor Gray
    $uriObj = [System.Uri]$targetUrl
    $portVal = 3000
    if ($uriObj.Port -gt 0) { $portVal = $uriObj.Port }
    $serverPayload = @{
        serverUrl = $targetUrl
        ip = $uriObj.Host
        port = $portVal
        updatedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json
    Invoke-RestMethod -Uri ($rtdbBase + "/server.json") -Method Put -Body $serverPayload -ContentType "application/json" | Out-Null
    Write-Host "      [OK] /server.json updated!" -ForegroundColor Green

    # 3. Update /config.json
    Write-Host "[3/3] Publishing to /config.json ..." -ForegroundColor Gray
    $configPayload = @{
        serverUrl = $targetUrl
    } | ConvertTo-Json
    Invoke-RestMethod -Uri ($rtdbBase + "/config.json") -Method Put -Body $configPayload -ContentType "application/json" | Out-Null
    Write-Host "      [OK] /config.json updated!" -ForegroundColor Green

    Write-Host ""
    Write-Host "SUCCESS: Server URL has been added to RTDB database!" -ForegroundColor Green
    Write-Host "Live URL: $targetUrl" -ForegroundColor Cyan
} catch {
    Write-Host "ERROR: Failed to update Firebase Realtime Database" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
