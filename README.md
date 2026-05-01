# Asuswrt-Merlin ProtonVPN Port Forwarding Auto-Deploy (v3.0.1)

An automated deployment architecture for Asuswrt-Merlin routers. This script dynamically retrieves assigned port forwarding numbers from ProtonVPN's NAT-PMP servers and seamlessly injects them into local P2P instances (like BiglyBT) via RPC.

**New in v3.0.0 (Multi-Tenant Architecture & Persistent Daemon):**
* **Persistent NAT-PMP Daemon:** Completely eliminates the Windows socket exhaustion bug! The architecture abandons 5-minute cron jobs in favor of a resilient 45-second background daemon that aggressively renews ProtonVPN's strict 60-second lease, ensuring the port never drops and connections safely garbage-collect.
* **Multi-Instance Support:** The deployment engine has been entirely refactored to support multiple independent port forwarding configurations concurrently, mapping multiple PCs across multiple WireGuard interfaces seamlessly.
* **Smart PID Management:** Avoids generic `killall` commands by tracking daemon PIDs (`/var/run/proton_pf_wgcX.pid`). The script self-terminates if the WireGuard interface drops, preventing zombie processes.
* **Namespaced Logging:** Includes a new `PF_LOG_LEVEL` configuration variable to silence repetitive 45-second keep-alive logs from the Asuswrt syslog while retaining critical failure/success messages.
* **Cross-Platform Safety:** Enforces `LF` line endings for all shell scripts via `.gitattributes`, permanently removing the need to run `dos2unix` when pushing from Windows to the Asus router.
* **Automated Data Migration:** Upgrading from v2.3.0 is completely seamless! The deployment script automatically migrates legacy configuration files into the new array-based multi-tenant format.

> [!WARNING]
> **Important Upgrade Notice:** When upgrading or migrating to v3.0.0, **you must ensure all WireGuard interfaces involved are DISCONNECTED (toggled off) prior to running the deployment.** If you have ongoing active connections during the upgrade, the automated legacy cleanup will fail to correctly identify and purge the old routing rules, which may lead to unpredictable firewall behavior.

**New in v2.3.0 (The Architecture Update):**
* **State-File Architecture:** The script lifecycle writes the active forwarded port to a volatile state file (`/var/run/proton_pf_wgcX_instanceY.port`) and gracefully exits. This permanently eliminates "zombie" background processes.
* **Bulletproof Firewall Cleanup:** Cleanly flushes the exact forwarded port from your router's `iptables` guaranteeing zero routing or memory leaks.
* **Firmware 3.0.0.6 (SDN) Native:** Bridges the isolated `main` routing table to the VPN Director to ensure the router can reach the ProtonVPN gateway on newer Asuswrt-Merlin branches.

## Features

* **Aggressive NAT Hole-Punching:** Asus VPN Director's strict inbound firewall blindly drops incoming torrent requests. This script dynamically injects precise `iptables` PREROUTING and FORWARD rules to route the port directly to your local PC, guaranteeing maximum upload speeds.
* **Dynamic TCP Socket Protection (Transmission API Compliant Clients):** For fully Transmission API-compliant clients, the script can automatically inject peer and speed limits via RPC. This prevents `java.net.SocketException` crashes on Windows by clamping down global connections when falling back from a high-power desktop VPN tunnel to the router's embedded VPN tunnel. *(Note: BiglyBT's Web Remote plugin currently only fully supports the port forwarding parameter).*
* **The "Patient Loop":** Includes a 30-minute automated retry loop. If the router connects to the VPN but the target PC/BitTorrent client is offline, the script waits silently and pushes the payload the moment it comes online, then safely terminates itself.
* **BusyBox Native:** Completely compatible with Asuswrt-Merlin's embedded shell. Uses native `awk` and `sed` to ensure zero silent failures on router hardware.
* **Non-Destructive Deployment:** Automatically generates collision-proof, chronologically timestamped backups of your existing `wgclient` scripts before executing any upgrades.

## Prerequisites

1. **Router:** Asus router running Asuswrt-Merlin firmware.
2. **Entware:** You must have Entware installed on a mounted USB drive, and the `natpmpc` package must be installed (`opkg install natpmpc`).
3. **VPN:** ProtonVPN Plus account with Port Forwarding enabled on a WireGuard connection.
4. **Client:** BiglyBT with the Web Remote (Transmission RPC) plugin enabled.
5. **Network:** Target PC must be routed through the WireGuard tunnel via the Asus VPN Director (with NAT enabled).

## Installation & Setup

### 1. Configure Credentials & Limits
Copy the example configuration file to your router and add your specific credentials. You can also configure your optional Session Limits here to protect your network stack.

```bash
cp .biglybt_config.example /jffs/scripts/.biglybt_config
nano /jffs/scripts/.biglybt_config
```

Secure the file so your credentials aren't exposed:

```bash
chmod 600 /jffs/scripts/.biglybt_config
```

**Note:** Ensure you define the `INSTANCE_IDS` array and correctly map `PF_X_WG_CLIENT_ID` for each instance in your config file so the deployment script knows which interfaces to hook into!

### 2. Deploy
Transfer the main script to your router via SCP:

```bash
scp deploy_proton_pf.sh your_router_user@192.168.1.1:/jffs/scripts/
```

SSH into your router and execute the deployment:

```bash
cd /jffs/scripts/
sh deploy_proton_pf.sh
```

### 3. Verify
Toggle your WireGuard client off and on in the Asus GUI. Check your system logs to verify the deployment:

```bash
grep "PortForward" /tmp/syslog.log
```

Look for: `PortForward: BiglyBT API (HTTP: 200) limits applied | Firewall routed port XXXXX to 192.168.1.XXX.`

## The "Hybrid" Workflow (Desktop vs. Router)
This utility perfectly supports users who switch between the native desktop ProtonVPN app and the Asus router VPN:
1. **Desktop Native Mode (App ON):** Use your PC's desktop CPU to handle massive peer connections and encryption overhead for high-speed downloads.
   - **Desktop Automation:** We have included a native Windows PowerShell script (`scripts/windows/Sync-ProtonPortBiglyBT.ps1`) to automatically fetch your active port! Instead of manually typing in the port from the ProtonVPN Windows app, simply configure `.windows_config.psd1` and run the script. It natively queries the local VPN gateway via NAT-PMP and pushes the port directly to BiglyBT.
2. **Router Mode (App OFF):** Let Windows automatically fall back to the Asus router gateway. The router establishes the tunnel, runs this script, and forwards the incoming port to your PC. *(For fully compliant RPC clients, it can also clamp active connections down to a safe limit so your router and Windows TCP stack can handle passive 24/7 background seeding without crashing).*

## Maintenance & Compatibility

**Important Note on `spdMerlin` (and other amtm addons):** Third-party router scripts like `spdMerlin` occasionally overwrite or aggressively inject their own blocking code into the router's `wgclient-start` and `wgclient-stop` event scripts during their update cycles. 

If you update `spdMerlin` and notice your port forwarding has suddenly stopped working, SSH into your router and verify that your `port_forward.sh` hooks are still present. If an update wiped them out, simply re-run the `deploy_proton_pf.sh` script to safely re-inject the hooks.

## Rollback
If you ever need to revert to your previous setup, simply check the `/jffs/scripts/` directory for your chronologically stamped backups (e.g., `wgclient-start.bak_YYYYMMDD_HHMMSS`), delete the active scripts, and rename the backups by removing the `.bak_timestamp` extension.

## Author
Xavier Chamoiseau

## Assisted by
Assisted by Gemini 3.1 Pro

## License
MIT License
