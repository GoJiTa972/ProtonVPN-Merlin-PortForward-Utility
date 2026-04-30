<#
.SYNOPSIS
    Syncs the active ProtonVPN Port Forwarding port to BiglyBT via RPC.
.DESCRIPTION
    This script natively queries the ProtonVPN Gateway via NAT-PMP to retrieve 
    the active forwarded port, bypassing the need to scrape Windows notifications.
    It then pushes the port to BiglyBT using its Web Remote (Transmission RPC) API.
.NOTES
    Author: Xavier Chamoiseau / Assisted by Gemini
#>

$ErrorActionPreference = "Stop"

# 1. Load Configuration
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir ".windows_config.psd1"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "[-] Configuration file not found at $ConfigFile" -ForegroundColor Red
    Write-Host "    Please copy .windows_config.psd1.example to .windows_config.psd1 and fill in your details." -ForegroundColor Yellow
    exit 1
}

$Config = Import-LocalizedData -BaseDirectory $ScriptDir -FileName ".windows_config.psd1"

# 2. Find the VPN Gateway IP
$GatewayIp = $null
Write-Host "[*] Detecting ProtonVPN Gateway..."

# If user specified an adapter in config
if (-not [string]::IsNullOrWhiteSpace($Config.ProtonVpnAdapterName)) {
    $Adapter = Get-NetAdapter -InterfaceDescription "*$($Config.ProtonVpnAdapterName)*" -ErrorAction SilentlyContinue
    if ($Adapter) {
        $NetIpConf = Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex
        if ($NetIpConf.IPv4DefaultGateway.NextHop -and $NetIpConf.IPv4DefaultGateway.NextHop -ne "0.0.0.0") {
            $GatewayIp = $NetIpConf.IPv4DefaultGateway.NextHop
        } elseif ($NetIpConf.IPv4Address) {
            $GatewayIp = "10.2.0.1"
        }
    }
}

# Fallback 1: Look for common ProtonVPN names
if (-not $GatewayIp) {
    $Adapters = Get-NetAdapter | Where-Object { ($_.InterfaceDescription -match "ProtonVPN|WireGuard|TAP-Windows" -or $_.Name -match "ProtonVPN") -and $_.Status -eq "Up" }
    foreach ($Adapter in $Adapters) {
        $NetIpConf = Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex
        if ($NetIpConf.IPv4DefaultGateway.NextHop -and $NetIpConf.IPv4DefaultGateway.NextHop -ne "0.0.0.0") {
            $GatewayIp = $NetIpConf.IPv4DefaultGateway.NextHop
            break
        } elseif ($NetIpConf.IPv4Address) {
            $GatewayIp = "10.2.0.1"
            break
        }
    }
}

# Fallback 2: ProtonVPN's standard NAT-PMP gateway IP
if (-not $GatewayIp) {
    Write-Host "[!] Could not detect gateway from adapters. Falling back to standard ProtonVPN gateway (10.2.0.1)." -ForegroundColor Yellow
    $GatewayIp = "10.2.0.1"
}

Write-Host "[+] Using VPN Gateway: $GatewayIp" -ForegroundColor Green

# 3. Query NAT-PMP for the Forwarded Port
Write-Host "[*] Querying NAT-PMP for active port mapping..."
$MappedPort = $null

try {
    $UdpClient = New-Object System.Net.Sockets.UdpClient
    $UdpClient.Client.ReceiveTimeout = 3000 # 3 seconds
    $UdpClient.Connect($GatewayIp, 5351)

    # NAT-PMP Map Request (TCP, Internal Port 0, External Port 0, Lifetime 60s)
    [byte[]]$Payload = @(0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3C)
    $UdpClient.Send($Payload, $Payload.Length) | Out-Null

    $RemoteIpEndPoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    [byte[]]$Response = $UdpClient.Receive([ref]$RemoteIpEndPoint)
    $UdpClient.Close()

    if ($Response.Length -ge 16 -and $Response[0] -eq 0 -and ($Response[1] -eq 130 -or $Response[1] -eq 129)) {
        # Network byte order (Big-Endian) parsing
        $ResultCode = ($Response[2] * 256) + $Response[3]
        if ($ResultCode -eq 0) {
            $MappedPort = ($Response[10] * 256) + $Response[11]
            Write-Host "[+] Successfully retrieved port: $MappedPort" -ForegroundColor Green
        } else {
            Write-Host "[-] NAT-PMP returned error code: $ResultCode" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "[-] Invalid NAT-PMP response received." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "[-] Failed to retrieve port via NAT-PMP. Make sure ProtonVPN Port Forwarding is enabled." -ForegroundColor Red
    Write-Host "    Error details: $_" -ForegroundColor DarkGray
    exit 1
}

# 4. Push the Port to Transmission RPC
if ($MappedPort) {
    Write-Host "[*] Pushing port $MappedPort to Transmission RPC client..."
    
    $RpcScheme = if ($Config.BiglyBTScheme) { $Config.BiglyBTScheme } else { "https" }
    $RpcUrl = "${RpcScheme}://$($Config.BiglyBTIp):$($Config.BiglyBTPort)/transmission/rpc"
    $AuthString = "$($Config.BiglyBTUser):$($Config.BiglyBTPass)"

    # Step 4a: Get Session ID
    $SessionId = $null
    try {
        # Using native curl.exe to support -k (insecure) for self-signed HTTPS certs
        $CurlOutput = curl.exe -k -s -i --connect-timeout 3 -u $AuthString $RpcUrl 2>&1
        $SessionIdLine = $CurlOutput | Select-String "X-Transmission-Session-Id:\s*(.+?)\s*$"
        
        if ($SessionIdLine) {
            $SessionId = $SessionIdLine.Matches[0].Groups[1].Value.Trim()
        } else {
            Write-Host "[-] Failed to retrieve Transmission Session ID. curl output:" -ForegroundColor Red
            $CurlOutput | Select-Object -First 5 | Write-Host -ForegroundColor DarkGray
            exit 1
        }
    } catch {
        Write-Host "[-] Failed to connect to Transmission RPC: $_" -ForegroundColor Red
        exit 1
    }

    if (-not $SessionId) {
        Write-Host "[-] Could not retrieve Transmission Session ID." -ForegroundColor Red
        exit 1
    }

    # Step 4b: Set the peer-port
    $JsonPayload = @{
        method = "session-set"
        arguments = @{
            "peer-port" = $MappedPort
        }
    } | ConvertTo-Json -Depth 5 -Compress
    
    # Escape quotes for cmd/curl
    $JsonPayload = $JsonPayload -replace '"', '\"'

    try {
        $ResponseOutput = curl.exe -k -s -w "%{http_code}" --connect-timeout 3 -u $AuthString -H "X-Transmission-Session-Id: $SessionId" -H "Content-Type: application/json" -H "Accept: application/json" -d "$JsonPayload" $RpcUrl
        
        if ($ResponseOutput -match "200$") {
            Write-Host "[+] Transmission RPC client updated successfully! Now listening on port $MappedPort." -ForegroundColor Green
            Write-Host "    Response: $ResponseOutput" -ForegroundColor DarkGray
        } else {
            Write-Host "[-] Transmission RPC error or unexpected status code." -ForegroundColor Red
            Write-Host "    Output: $ResponseOutput" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "[-] Failed to send payload to Transmission RPC client: $_" -ForegroundColor Red
        exit 1
    }
}
