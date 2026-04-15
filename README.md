# protonvpn-merlin-portforward

## Core Features (v2)

* **Dynamic NAT-PMP Polling:** Automatically queries ProtonVPN's internal gateway (`10.2.0.1`) using native `natpmpc` to retrieve the dynamic port.
* **The "Patient Loop":** Includes a 30-minute automated retry loop. If the router connects to the VPN but the target PC/BiglyBT is offline, the script waits silently in the background and pushes the payload the moment BiglyBT comes online.
* **Aggressive NAT Hole-Punching:** Asus VPN Director's strict inbound firewall will blindly drop incoming torrent requests. This script dynamically injects (and cleans up) precise `iptables` PREROUTING and FORWARD rules to route the specific port directly to your torrent client, guaranteeing maximum upload speeds.
* **Non-Destructive Hooks:** Automatically generates chronologically timestamped backups of existing `/jffs/scripts/wgclient` scripts before injecting safe, non-blocking background hooks.