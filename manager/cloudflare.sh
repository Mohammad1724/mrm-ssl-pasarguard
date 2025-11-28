#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

CF_CONFIG="/root/.mrm_cloudflare"

load_cf_credentials() {
    if [ -f "$CF_CONFIG" ]; then
        source "$CF_CONFIG"
    fi
}

save_cf_credentials() {
    echo "CF_EMAIL=\"$CF_EMAIL\"" > "$CF_CONFIG"
    echo "CF_KEY=\"$CF_KEY\"" >> "$CF_CONFIG"
    echo "CF_ZONE_ID=\"$CF_ZONE_ID\"" >> "$CF_CONFIG"
    chmod 600 "$CF_CONFIG"
}

cf_setup_wizard() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      CLOUDFLARE API SETUP                   ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    load_cf_credentials
    
    if [ -n "$CF_EMAIL" ]; then
        echo -e "Saved Email: ${CYAN}$CF_EMAIL${NC}"
        echo -e "Saved Key:   ${CYAN}${CF_KEY:0:5}******${NC}"
        echo ""
        read -p "Change credentials? (y/n): " CHANGE
        if [ "$CHANGE" != "y" ]; then return; fi
    fi
    
    echo -e "${YELLOW}You need your Global API Key from Cloudflare.${NC}"
    echo "Go to: My Profile > API Tokens > Global API Key > View"
    echo ""
    
    read -p "Cloudflare Email: " CF_EMAIL
    read -p "Global API Key: " CF_KEY
    
    [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ] && { echo "Cancelled."; pause; return; }
    
    save_cf_credentials
    echo -e "${GREEN}✔ Credentials Saved.${NC}"
    pause
}

cf_add_dns() {
    load_cf_credentials
    
    if [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
        echo -e "${RED}Please setup API credentials first!${NC}"
        pause
        return
    fi
    
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      ADD DNS RECORD (A)                     ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    
    read -p "Zone ID (Domain ID): " ZONE_ID
    if [ -z "$ZONE_ID" ] && [ -n "$CF_ZONE_ID" ]; then
        ZONE_ID="$CF_ZONE_ID"
        echo -e "Using saved Zone ID: ${CYAN}$ZONE_ID${NC}"
    fi
    
    if [ -z "$ZONE_ID" ]; then
         echo -e "${RED}Zone ID is required!${NC}"
         echo "(Find it on the right side of Cloudflare Overview page)"
         pause; return
    fi
    
    CF_ZONE_ID="$ZONE_ID"
    save_cf_credentials
    
    read -p "Subdomain (e.g., vpn): " SUBDOMAIN
    [ -z "$SUBDOMAIN" ] && { echo "Cancelled."; pause; return; }
    
    # Get current IP
    local CURRENT_IP=$(curl -s -4 ifconfig.me)
    read -p "IP Address [$CURRENT_IP]: " IP_ADDR
    [ -z "$IP_ADDR" ] && IP_ADDR="$CURRENT_IP"
    
    read -p "Proxy Status (true/false) [false]: " PROXIED
    [ -z "$PROXIED" ] && PROXIED="false"
    
    echo -e "${BLUE}Creating Record...${NC}"
    
    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
         -H "X-Auth-Email: $CF_EMAIL" \
         -H "X-Auth-Key: $CF_KEY" \
         -H "Content-Type: application/json" \
         --data '{"type":"A","name":"'"$SUBDOMAIN"'","content":"'"$IP_ADDR"'","ttl":120,"proxied":'$PROXIED'}')
         
    if echo "$RESPONSE" | grep -q '"success":true'; then
        echo -e "${GREEN}✔ DNS Record Created!${NC}"
        echo -e "Domain: ${CYAN}$SUBDOMAIN (A -> $IP_ADDR)${NC}"
    else
        echo -e "${RED}✘ Failed!${NC}"
        echo "$RESPONSE"
    fi
    
    pause
}

cf_set_ssl_full() {
    load_cf_credentials
    if [ -z "$CF_EMAIL" ] || [ -z "$CF_ZONE_ID" ]; then
        echo -e "${RED}Setup credentials & Zone ID first!${NC}"
        pause; return
    fi
    
    echo -e "${BLUE}Setting SSL to Full (Strict)...${NC}"
    
    RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/settings/ssl" \
         -H "X-Auth-Email: $CF_EMAIL" \
         -H "X-Auth-Key: $CF_KEY" \
         -H "Content-Type: application/json" \
         --data '{"value":"full"}')
         
    if echo "$RESPONSE" | grep -q '"success":true'; then
        echo -e "${GREEN}✔ SSL set to FULL.${NC}"
    else
        echo -e "${RED}✘ Failed.${NC}"
        echo "$RESPONSE"
    fi
    pause
}

cloudflare_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      CLOUDFLARE MANAGER                   ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Setup API Credentials"
        echo "2) Add DNS Record (A)"
        echo "3) Set SSL Mode to FULL"
        echo "4) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) cf_setup_wizard ;;
            2) cf_add_dns ;;
            3) cf_set_ssl_full ;;
            4) return ;;
            *) ;;
        esac
    done
}