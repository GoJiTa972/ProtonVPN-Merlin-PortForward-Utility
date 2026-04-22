#!/bin/sh

CONFIG_FILE="/jffs/scripts/.biglybt_config"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    logger -t "PortForward" "Error: Config file missing. Aborting."
    exit 1
fi

# --- GRACEFUL CLEANUP TRAP ---
cleanup() {
    if [ -n "$CURRENT_PORT" ]; then
        logger -t "PortForward" "Termination signal received. Cleaning up iptables rules for port $CURRENT_PORT..."
        iptables -t nat -D PREROUTING -i wgc$WG_CLIENT_ID -p tcp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP 2>/dev/null
        iptables -t nat -D PREROUTING -i wgc$WG_CLIENT_ID -p udp --dport $CURRENT_PORT -j DNAT --to-destination $PC_IP 2>/dev/null
        iptables -D FORWARD -i wgc$WG_CLIENT_ID -p tcp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT 2>/dev/null
        iptables -D FORWARD -i wgc$WG_CLIENT_ID -p udp -d $PC_IP --dport $CURRENT_PORT -j ACCEPT 2>/dev/null
    fi
    exit 0
}
trap cleanup TERM INT

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