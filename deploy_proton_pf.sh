#!/bin/sh
# =================================================================
# ProtonVPN + BiglyBT Port Forward Deployment (v2.2.0)
# Author: GoJiTa972 (Xavier Chamoiseau)
# =================================================================

CONFIG_FILE="/jffs/scripts/.biglybt_config"

echo "Starting deployment..."

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file missing at $CONFIG_FILE. Deployment aborted."
    echo "Please copy .biglybt_config_example to $CONFIG_FILE and fill in your details."
    exit 1
fi

. "$CONFIG_FILE"

# --- 0. BACKUP EXISTING SCRIPTS ---
echo "Running pre-flight backups..."
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

[ -f /jffs/scripts/port_forward.sh ] && cp /jffs/scripts/port_forward.sh /jffs/scripts/port_forward.sh.bak_$TIMESTAMP
[ -f /jffs/scripts/wgclient-start ] && cp /jffs/scripts/wgclient-start /jffs/scripts/wgclient-start.bak_$TIMESTAMP
[ -f /jffs/scripts/wgclient-stop ] && cp /jffs/scripts/wgclient-stop /jffs/scripts/wgclient-stop.bak_$TIMESTAMP
echo "Backups secured with timestamp: $TIMESTAMP"

# --- 1. BUILD THE MAIN SCRIPT ---
echo "Writing /jffs/scripts/port_forward.sh..."

cat << 'EOF' > /jffs/scripts/port_forward.sh
#!/bin/sh

CONFIG_FILE="/jffs/scripts/.biglybt_config"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    logger -t "PortForward" "Error: Config file missing. Aborting."
    exit 1
fi

# Allow tunnel to stabilize
sleep 10

# --- FIRMWARE 3.0.0.6 ROUTING FIX ---
# Ensure the router's main routing table can reach the VPN gateway
ip route add "$VPN_GW" dev "wgc$WG_CLIENT_ID" 2>/dev/null

# Entware / natpmpc validation
if ! which natpmpc >/dev/null 2>&1; then
    logger -t "PortForward" "Error: natpmpc not found. Ensure Entware is mounted and natpmpc is installed."
    exit 1
fi

CURRENT_PORT=$(natpmpc -a 1 0 udp 60 -g "$VPN_GW" | grep -i "Mapped public port" | awk '{print $4}')

if [ -n "$CURRENT_PORT" ]; then
    logger -t "PortForward" "Successfully pulled port: $CURRENT_PORT. Waiting for BiglyBT..."
    
    ATTEMPT=0
    MAX_ATTEMPTS=60
    
    # 30-Minute Patient Loop
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        TR_SESSION=$(curl -k -s -i --connect-timeout 3 -u "$RPC_USER:$RPC_PASS" "$RPC_URL" 2>/dev/null | grep -i "X-Transmission-Session-Id:" | awk '{print $2}' | tr -d '\r')
            
        if [ -n "$TR_SESSION" ]; then
            
            # --- BUILD DYNAMIC JSON PAYLOAD ---
            ARGUMENTS='"peer-port": '$CURRENT_PORT
            
            [ -n "$LIMIT_GLOBAL" ] && ARGUMENTS="${ARGUMENTS}, \"peer-limit-global\": $LIMIT_GLOBAL"
            [ -n "$LIMIT_PER_TORRENT" ] && ARGUMENTS="${ARGUMENTS}, \"peer-limit-per-torrent\": $LIMIT_PER_TORRENT"
            [ -n "$LIMIT_UP_KBPS" ] && ARGUMENTS="${ARGUMENTS}, \"speed-limit-up\": $LIMIT_UP_KBPS"
            [ -n "$LIMIT_UP_ENABLED" ] && ARGUMENTS="${ARGUMENTS}, \"speed-limit-up-enabled\": $LIMIT_UP_ENABLED"
            
            PAYLOAD='{"method":"session-set","arguments":{'$ARGUMENTS'}}'

            # Push the port and limits to BiglyBT RPC
            HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 3 -u "$RPC_USER:$RPC_PASS" -H "X-Transmission-Session-Id: $TR_SESSION" -d "$PAYLOAD" "$RPC_URL")
            
            # --- FIREWALL HOLE PUNCH ---
            # Flush existing rules to prevent duplicates
            iptables -t nat -D PREROUTING -i wgc$WG_CLIENT_ID -p tcp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP 2>/dev/null
            iptables -t nat -D PREROUTING -i wgc$WG_CLIENT_ID -p udp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP 2>/dev/null
            iptables -D FORWARD -i wgc$WG_CLIENT_ID -p tcp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT 2>/dev/null
            iptables -D FORWARD -i wgc$WG_CLIENT_ID -p udp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT 2>/dev/null

            # Insert precise routing rules for VPN Director compatibility
            iptables -t nat -I PREROUTING -i wgc$WG_CLIENT_ID -p tcp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP
            iptables -t nat -I PREROUTING -i wgc$WG_CLIENT_ID -p udp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP
            iptables -I FORWARD -i wgc$WG_CLIENT_ID -p tcp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT
            iptables -I FORWARD -i wgc$WG_CLIENT_ID -p udp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT
            
            logger -t "PortForward" "BiglyBT API (HTTP: $HTTP_CODE) limits applied | Firewall routed port $CURRENT_PORT to $PC_IP."
            break
        fi
        
        sleep 30
        ATTEMPT=$((ATTEMPT+1))
    done

    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        logger -t "PortForward" "Gave up waiting for BiglyBT after 30 minutes."
    fi
else
    logger -t "PortForward" "Failed to retrieve port from natpmpc."
fi
EOF

chmod +x /jffs/scripts/port_forward.sh

# --- 2. HOOK WGCLIENT-START (Idempotent Injection) ---
echo "Checking wgclient-start..."
if [ ! -f /jffs/scripts/wgclient-start ]; then
    echo "#!/bin/sh" > /jffs/scripts/wgclient-start
fi

# Purge legacy unmarked hooks (v2.1.2 and older)
sed -i '/# --- ProtonVPN Port Forwarding Hook ---/,/^fi/d' /jffs/scripts/wgclient-start
# Purge any existing marked hooks (v2.2.0+)
sed -i '/# --- BEGIN PROTONVPN PF HOOK ---/,/# --- END PROTONVPN PF HOOK ---/d' /jffs/scripts/wgclient-start

echo "Injecting fresh start hook for wgc$WG_CLIENT_ID..."
cat << EOF >> /jffs/scripts/wgclient-start

# --- BEGIN PROTONVPN PF HOOK ---
# Injected by deploy_proton_pf.sh - Do not modify these marker lines
if [ "\$1" = "$WG_CLIENT_ID" ] || [ "\$1" = "wgc$WG_CLIENT_ID" ]; then
    killall port_forward.sh 2>/dev/null
    nohup /jffs/scripts/port_forward.sh > /dev/null 2>&1 &
fi
# --- END PROTONVPN PF HOOK ---
EOF
chmod +x /jffs/scripts/wgclient-start

# --- 3. HOOK WGCLIENT-STOP (Idempotent Injection) ---
echo "Checking wgclient-stop..."
if [ ! -f /jffs/scripts/wgclient-stop ]; then
    echo "#!/bin/sh" > /jffs/scripts/wgclient-stop
fi

# Purge legacy unmarked hooks (v2.1.2 and older)
sed -i '/# --- ProtonVPN Port Forwarding Hook ---/,/^fi/d' /jffs/scripts/wgclient-stop
# Purge any existing marked hooks (v2.2.0+)
sed -i '/# --- BEGIN PROTONVPN PF HOOK ---/,/# --- END PROTONVPN PF HOOK ---/d' /jffs/scripts/wgclient-stop

echo "Injecting fresh stop hook for wgc$WG_CLIENT_ID..."
cat << EOF >> /jffs/scripts/wgclient-stop

# --- BEGIN PROTONVPN PF HOOK ---
# Injected by deploy_proton_pf.sh - Do not modify these marker lines
if [ "\$1" = "$WG_CLIENT_ID" ] || [ "\$1" = "wgc$WG_CLIENT_ID" ]; then
    killall port_forward.sh 2>/dev/null
fi
# --- END PROTONVPN PF HOOK ---
EOF
chmod +x /jffs/scripts/wgclient-stop

echo "Deployment Complete! Scripts and hooks are live for WireGuard Client $WG_CLIENT_ID."