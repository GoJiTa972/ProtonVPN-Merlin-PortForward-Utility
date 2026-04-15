# Asuswrt-Merlin ProtonVPN Port Forwarding Auto-Deploy (v2)

An automated deployment architecture for Asuswrt-Merlin routers. This script dynamically retrieves assigned port forwarding numbers from ProtonVPN's NAT-PMP servers and seamlessly injects them into a local BiglyBT instance via RPC, completely bypassing the Asus VPN Director's split-tunneling inbound firewall limitations.

## Features

* **Aggressive NAT Hole-Punching:** Asus VPN Director's strict inbound firewall blindly drops incoming torrent requests. This script dynamically injects precise `iptables` PREROUTING and FORWARD rules to route the port directly to your local PC, guaranteeing maximum upload speeds.
* **The "Patient Loop":** Includes a 30-minute automated retry loop. If the router connects to the VPN but the target PC/BiglyBT is offline, the script waits silently and pushes the payload the moment BiglyBT comes online.
* **BusyBox Native:** Completely compatible with Asuswrt-Merlin's embedded shell. Uses native `awk` to ensure zero silent failures on router hardware.
* **Non-Destructive Deployment:** Automatically generates collision-proof, chronologically timestamped backups of your existing `wgclient` scripts before injecting new, non-blocking hooks.

## Prerequisites

1. **Router:** Asus router running Asuswrt-Merlin firmware.
2. **VPN:** ProtonVPN Plus account with Port Forwarding enabled on a WireGuard connection.
3. **Client:** BiglyBT with the Web Remote (RPC) plugin enabled.
4. **Network:** Target PC must be routed through the WireGuard tunnel via the Asus VPN Director (with NAT enabled).

## Installation & Setup

### 1. Configure Credentials
Copy the example configuration file to your router and add your specific credentials.

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

Look for: `PortForward: BiglyBT API (HTTP: 200) | Firewall routed port XXXXX to 192.168.1.XXX.`

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
