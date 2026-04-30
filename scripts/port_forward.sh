#!/bin/sh

INSTANCE_ID="$1"
if [ -z "$INSTANCE_ID" ]; then
    logger -t "PortForward" "Error: Missing INSTANCE_ID argument."
    exit 1
fi

CONFIG_FILE="/jffs/scripts/.biglybt_config"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    logger -t "PortForward" "Error: Config file missing. Aborting."
    exit 1
fi

# Load instance variables
eval WG_CLIENT_ID="\$PF_${INSTANCE_ID}_WG_CLIENT_ID"
eval VPN_GW="\$PF_${INSTANCE_ID}_VPN_GW"
eval PC_IP="\$PF_${INSTANCE_ID}_PC_IP"
eval RPC_PORT="\$PF_${INSTANCE_ID}_RPC_PORT"
eval RPC_SCHEME="\$PF_${INSTANCE_ID}_RPC_SCHEME"
eval RPC_USER="\$PF_${INSTANCE_ID}_RPC_USER"
eval RPC_PASS="\$PF_${INSTANCE_ID}_RPC_PASS"
eval LIMIT_GLOBAL="\$PF_${INSTANCE_ID}_LIMIT_GLOBAL"
eval LIMIT_PER_TORRENT="\$PF_${INSTANCE_ID}_LIMIT_PER_TORRENT"
eval LIMIT_UP_KBPS="\$PF_${INSTANCE_ID}_LIMIT_UP_KBPS"
eval LIMIT_UP_ENABLED="\$PF_${INSTANCE_ID}_LIMIT_UP_ENABLED"

# Strip potential Windows CRLF carriage returns to prevent malformed URLs and JSON payloads
WG_CLIENT_ID=$(echo "$WG_CLIENT_ID" | tr -d '\r')
VPN_GW=$(echo "$VPN_GW" | tr -d '\r')
PC_IP=$(echo "$PC_IP" | tr -d '\r')
RPC_PORT=$(echo "$RPC_PORT" | tr -d '\r')
RPC_SCHEME=$(echo "${RPC_SCHEME:-https}" | tr -d '\r')
RPC_USER=$(echo "$RPC_USER" | tr -d '\r')
RPC_PASS=$(echo "$RPC_PASS" | tr -d '\r')
LIMIT_GLOBAL=$(echo "$LIMIT_GLOBAL" | tr -d '\r')
LIMIT_PER_TORRENT=$(echo "$LIMIT_PER_TORRENT" | tr -d '\r')
LIMIT_UP_KBPS=$(echo "$LIMIT_UP_KBPS" | tr -d '\r')
LIMIT_UP_ENABLED=$(echo "$LIMIT_UP_ENABLED" | tr -d '\r')

RPC_URL="${RPC_SCHEME}://$PC_IP:$RPC_PORT/transmission/rpc"

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
    logger -t "PortForward" "[Instance $INSTANCE_ID] Successfully pulled port: $CURRENT_PORT. Waiting for Transmission RPC client... (URL: $RPC_URL, User: $RPC_USER)"
    
    ATTEMPT=0
    MAX_ATTEMPTS=60
    
    # 30-Minute Patient Loop
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        CURL_OUTPUT=$(curl -k -s -S -i --connect-timeout 3 -u "$RPC_USER:$RPC_PASS" "$RPC_URL" 2>&1)
        TR_SESSION=$(echo "$CURL_OUTPUT" | grep -i "X-Transmission-Session-Id:" | awk '{print $2}' | tr -d '\r')
            
        if [ -n "$TR_SESSION" ]; then
            
            # --- BUILD DYNAMIC JSON PAYLOAD ---
            ARGUMENTS='"peer-port": '$CURRENT_PORT
            
            [ -n "$LIMIT_GLOBAL" ] && ARGUMENTS="${ARGUMENTS}, \"peer-limit-global\": $LIMIT_GLOBAL"
            [ -n "$LIMIT_PER_TORRENT" ] && ARGUMENTS="${ARGUMENTS}, \"peer-limit-per-torrent\": $LIMIT_PER_TORRENT"
            [ -n "$LIMIT_UP_KBPS" ] && ARGUMENTS="${ARGUMENTS}, \"speed-limit-up\": $LIMIT_UP_KBPS"
            [ -n "$LIMIT_UP_ENABLED" ] && ARGUMENTS="${ARGUMENTS}, \"speed-limit-up-enabled\": $LIMIT_UP_ENABLED"
            
            PAYLOAD='{"method":"session-set","arguments":{'$ARGUMENTS'}}'

            # Push the port and limits to Transmission RPC
            HTTP_CODE=$(curl -k -s -o /tmp/biglybt_rpc_response_${INSTANCE_ID}.json -w "%{http_code}" --connect-timeout 3 -u "$RPC_USER:$RPC_PASS" -H "X-Transmission-Session-Id: $TR_SESSION" -H "Content-Type: application/json" -H "Accept: application/json" -d "$PAYLOAD" "$RPC_URL")
            BODY=$(cat /tmp/biglybt_rpc_response_${INSTANCE_ID}.json 2>/dev/null | tr -d '\n' | cut -c 1-100)
            
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
            
            # --- SAVE STATE ---
            # Save the active port to a volatile run file so the stop hook can clean it up later
            echo "$CURRENT_PORT" > "/var/run/proton_pf_wgc${WG_CLIENT_ID}_instance${INSTANCE_ID}.port"
            
            logger -t "PortForward" "[Instance $INSTANCE_ID] Transmission RPC API (HTTP: $HTTP_CODE) limits applied | Firewall routed port $CURRENT_PORT to $PC_IP. Response: $BODY"
            break
        else
            DEBUG_SNIPPET=$(echo "$CURL_OUTPUT" | head -n 3 | tr '\n' ' ' | cut -c 1-150)
            logger -t "PortForward" "[Instance $INSTANCE_ID] (Attempt $ATTEMPT) Failed to get session ID. Curl output: $DEBUG_SNIPPET"
        fi
        
        sleep 30
        ATTEMPT=$((ATTEMPT+1))
    done

    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        logger -t "PortForward" "[Instance $INSTANCE_ID] Gave up waiting for Transmission RPC client after 30 minutes."
    fi
else
    logger -t "PortForward" "[Instance $INSTANCE_ID] Failed to retrieve port from natpmpc."
fi