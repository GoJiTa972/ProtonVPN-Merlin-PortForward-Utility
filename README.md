# Asuswrt-Merlin ProtonVPN Port Forwarding Auto-Deploy (v2.2.0)

An automated deployment architecture for Asuswrt-Merlin routers. This script dynamically retrieves assigned port forwarding numbers from ProtonVPN's NAT-PMP servers and seamlessly injects them into a local BiglyBT instance via RPC, completely bypassing the Asus VPN Director's split-tunneling inbound firewall limitations.

**New in v2.2.0 (The Deployment Update):** * **Idempotent Hook Injection:** The deployment script now uses strict `sed` block markers. You can run the installer as many times as you want without duplicating code or leaving ghost processes behind.
* **Seamless Legacy Upgrades:** Automatically hunts down and safely purges older, un-marked `wgclient` hooks from previous versions (v2.1.2 and below) before installing the new engine.
* **Firmware 3.0.0.6 (SDN) Routing Fix:** Resolves NAT-PMP timeout errors on the newer Asuswrt-Merlin 3.0.0.6 branches (e.g., RT-AX86U Pro). The script dynamically bridges the isolated `main` routing table to the VPN Director to ensure the router's root shell can successfully reach the ProtonVPN gateway.

## Features

* **Aggressive NAT Hole-Punching:** Asus VPN Director's strict inbound firewall blindly drops incoming torrent requests. This script dynamically injects precise `iptables` PREROUTING and FORWARD rules to route the port directly to your local PC, guaranteeing maximum upload speeds.
* **Dynamic TCP Socket Protection:** Automatically injects peer and speed limits into BiglyBT via RPC. This prevents `java.net.SocketException` crashes on Windows by clamping down global connections when falling back from a high-power desktop VPN tunnel to the router's embedded VPN tunnel.
* **The "Patient Loop":** Includes a 30-minute automated retry loop. If the router connects to the VPN but the target PC/BiglyBT is offline, the script waits silently and pushes the payload the moment BiglyBT comes online.
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

## The "Hybrid" Workflow (Burst vs. Router Mode)
This utility perfectly supports users who switch between the native desktop ProtonVPN app and the Asus router VPN:
1. **Burst Mode (Desktop App ON):** Use your PC's desktop CPU to handle massive peer connections and encryption overhead for high-speed downloads without limits.
2. **Router Mode (Desktop App OFF):** Let Windows automatically fall back to the Asus router gateway. The router establishes the tunnel, runs this script, forwards the incoming port, and explicitly clamps BiglyBT's active connections down to a safe limit (e.g., 200 peers) so your router and Windows TCP stack can handle passive 24/7 background seeding without crashing.

## Maintenance & Compatibility

**Important Note on `spdMerlin` (and other amtm addons):** Third-party router scripts like `spdMerlin` occasionally overwrite or aggressively inject their own blocking code into the router's `wgclient-start` and `wgclient-stop` event scripts during their update cycles. 

If you update `spdMerlin` and notice your port forwarding has suddenly stopped working, SSH into your router and verify that your `port_forward.sh` hooks are still present in those two files. If an update wiped them out, simply re-run the `deploy_proton_pf.sh` script to safely re-inject the hooks.

## Rollback
If you ever need to revert to your previous setup, simply check the `/jffs/scripts/` directory for your chronologically stamped backups (e.g., `wgclient-start.bak_YYYYMMDD_HHMMSS`), delete the active scripts, and rename the backups by removing the `.bak_timestamp` extension.

## Author
Xavier Chamoiseau

## Assisted by
Assisted by Gemini 3.1 Pro

## License
MIT License