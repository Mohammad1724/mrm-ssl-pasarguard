#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

# Show Node SSL Paths & Files
show_node_ssl() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      NODE SSL CERTIFICATES                  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ ! -d "$NODE_DEF_CERTS" ]; then
        echo -e "${RED}Node certificate directory not found!${NC}"
        echo -e "Expected: ${CYAN}$NODE_DEF_CERTS${NC}"
        pause
        return
    fi

    local FOUND=0

    for dir in "$NODE_DEF_CERTS"/*/; do
        [ -d "$dir" ] || continue
        FOUND=1
        local domain=$(basename "$dir")

        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}Domain: $domain${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        # Certificate Path
        if [ -f "$dir/server.crt" ]; then
            echo -e "${BLUE}Certificate:${NC}"
            echo -e "  Path: ${CYAN}${dir}server.crt${NC}"

            # Show expiry date (with error handling)
            local EXPIRY=$(openssl x509 -enddate -noout -in "${dir}server.crt" 2>/dev/null | cut -d= -f2)
            if [ -n "$EXPIRY" ]; then
                echo -e "  Expires: ${CYAN}$EXPIRY${NC}"
            else
                echo -e "  Expires: ${RED}Unable to read${NC}"
            fi
            echo ""
        else
            echo -e "${RED}  Certificate not found (server.crt)${NC}"
        fi

        # Key Path
        if [ -f "${dir}server.key" ]; then
            echo -e "${BLUE}Private Key:${NC}"
            echo -e "  Path: ${CYAN}${dir}server.key${NC}"
            echo ""
        else
            echo -e "${RED}  Key not found (server.key)${NC}"
        fi

    done

    if [ $FOUND -eq 0 ]; then
        echo -e "${YELLOW}No certificates found in $NODE_DEF_CERTS${NC}"
        echo ""
        echo "To add certificates for node:"
        echo "1) Go to SSL Menu"
        echo "2) Generate new SSL"
        echo "3) Select 'Node Server' when asked"
    fi

    pause
}

# View Node SSL Content
view_node_ssl_content() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      VIEW NODE SSL CONTENT                  ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    if [ ! -d "$NODE_DEF_CERTS" ]; then
        echo -e "${RED}No certificates directory found!${NC}"
        pause
        return
    fi

    echo -e "${BLUE}Available Domains:${NC}"
    echo ""

    local i=1
    declare -a domains
    for dir in "$NODE_DEF_CERTS"/*/; do
        [ -d "$dir" ] || continue
        local domain=$(basename "$dir")
        domains[$i]="$domain"
        echo -e "  ${GREEN}$i)${NC} $domain"
        ((i++))
    done

    if [ $i -eq 1 ]; then
        echo -e "${YELLOW}No domains found.${NC}"
        pause
        return
    fi

    echo ""
    read -p "Select domain number: " NUM
    local SELECTED="${domains[$NUM]}"

    if [ -z "$SELECTED" ]; then
        echo -e "${RED}Invalid selection.${NC}"
        pause
        return
    fi

    local TARGET_DIR="$NODE_DEF_CERTS/$SELECTED"

    echo ""
    echo "Which file to view?"
    echo "1) Certificate (server.crt)"
    echo "2) Private Key (server.key)"
    read -p "Select: " F_OPT

    local FILE=""
    case $F_OPT in
        1) FILE="server.crt" ;;
        2) FILE="server.key" ;;
        *) return ;;
    esac

    if [ -f "$TARGET_DIR/$FILE" ]; then
        clear
        echo -e "${YELLOW}━━━ $SELECTED / $FILE ━━━${NC}"
        echo ""
        cat "$TARGET_DIR/$FILE"
        echo ""
        echo -e "${YELLOW}━━━ END OF FILE ━━━${NC}"
    else
        echo -e "${RED}File not found!${NC}"
    fi

    pause
}