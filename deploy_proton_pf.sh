#!/bin/sh
# =================================================================
# ProtonVPN + BiglyBT Port Forward Deployment (v2 - NAT Routing)
# Author: Xavier
# =================================================================

CONFIG_FILE="/jffs/scripts/.biglybt_config"

echo "Starting deployment..."

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file missing at $CONFIG_FILE. Deployment aborted."
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

sleep 10

CURRENT_PORT=$(natpmpc -a 1 0 udp 60 -g "$VPN_GW" | grep -i "Mapped public port" | awk '{print $4}')

if [ -n "$CURRENT_PORT" ]; then
    logger -t "PortForward" "Successfully pulled port: $CURRENT_PORT. Waiting for BiglyBT..."
    
    ATTEMPT=0
    MAX_ATTEMPTS=60
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        TR_SESSION=$(curl -k -s -i --connect-timeout 3 -u "$RPC_USER:$RPC_PASS" "$RPC_URL" 2>/dev/null | grep -i "X-Transmission-Session-Id:" | awk '{print $2}' | tr -d '\r')
            
        if [ -n "$TR_SESSION" ]; then
            # Push the port to BiglyBT
            HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 3 -u "$RPC_USER:$RPC_PASS" -H "X-Transmission-Session-Id: $TR_SESSION" -d '{"method":"session-set","arguments":{"peer-port":'$CURRENT_PORT'}}' "$RPC_URL")
            
            # --- FIREWALL HOLE PUNCH ---
            # Flush any lingering rules targeting our PC on this interface just to be perfectly clean
            iptables -t nat -D PREROUTING -i wgc$WG_CLIENT_ID -p tcp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP 2>/dev/null
            iptables -t nat -D PREROUTING -i wgc$WG_CLIENT_ID -p udp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP 2>/dev/null
            iptables -D FORWARD -i wgc$WG_CLIENT_ID -p tcp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT 2>/dev/null
            iptables -D FORWARD -i wgc$WG_CLIENT_ID -p udp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT 2>/dev/null

            # Insert new precise routing rules
            iptables -t nat -I PREROUTING -i wgc$WG_CLIENT_ID -p tcp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP
            iptables -t nat -I PREROUTING -i wgc$WG_CLIENT_ID -p udp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP
            iptables -I FORWARD -i wgc$WG_CLIENT_ID -p tcp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT
            iptables -I FORWARD -i wgc$WG_CLIENT_ID -p udp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT
            
            logger -t "PortForward" "BiglyBT API (HTTP: $HTTP_CODE) | Firewall routed port $CURRENT_PORT to $PC_IP."
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

# --- 2. HOOK WGCLIENT-START ---
echo "Checking wgclient-start..."
if [ ! -f /jffs/scripts/wgclient-start ]; then
    echo "#!/bin/sh" > /jffs/scripts/wgclient-start
fi

if ! grep -q "port_forward.sh" /jffs/scripts/wgclient-start; then
    echo "Injecting start hook for wgc$WG_CLIENT_ID..."
    cat << EOF >> /jffs/scripts/wgclient-start

# --- ProtonVPN Port Forwarding Hook ---
if [ "\$1" = "$WG_CLIENT_ID" ]; then
    killall port_forward.sh 2>/dev/null
    nohup /jffs/scripts/port_forward.sh > /dev/null 2>&1 &
fi
EOF
fi
chmod +x /jffs/scripts/wgclient-start

# --- 3. HOOK WGCLIENT-STOP ---
echo "Checking wgclient-stop..."
if [ ! -f /jffs/scripts/wgclient-stop ]; then
    echo "#!/bin/sh" > /jffs/scripts/wgclient-stop
fi

if ! grep -q "port_forward.sh" /jffs/scripts/wgclient-stop; then
    echo "Injecting stop hook for wgc$WG_CLIENT_ID..."
    cat << EOF >> /jffs/scripts/wgclient-stop

# --- ProtonVPN Port Forwarding Hook ---
if [ "\$1" = "$WG_CLIENT_ID" ]; then
    killall port_forward.sh 2>/dev/null
fi
EOF
fi
chmod +x /jffs/scripts/wgclient-stop

echo "Deployment Complete! Scripts and hooks are live for WireGuard Client $WG_CLIENT_ID."