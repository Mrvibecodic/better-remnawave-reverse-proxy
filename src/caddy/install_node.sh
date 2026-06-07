#!/bin/bash
# Module: Install Node Nginx

install_node_caddy() {
    # Load selfsteal templates module
    load_selfsteal_templates_module

    mkdir -p /opt/remnanode && cd /opt/remnanode

    reading "${LANG[SELFSTEAL]}" SELFSTEAL_DOMAIN

    check_domain "$SELFSTEAL_DOMAIN" true false
    local domain_check_result=$?
    if [ $domain_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    while true; do
        reading "${LANG[PANEL_IP_PROMPT]}" PANEL_IP
        if echo "$PANEL_IP" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null && \
           [[ $(echo "$PANEL_IP" | tr '.' '\n' | wc -l) -eq 4 ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -vE '^[0-9]{1,3}$') ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -E '^(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})$') ]]; then
            break
        else
            echo -e "${COLOR_RED}${LANG[IP_ERROR]}${COLOR_RESET}"
        fi
    done

    echo -n "$(question "${LANG[CERT_PROMPT]}")"
    CERTIFICATE=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ -n "$CERTIFICATE" ]; then
                break
            fi
        else
            CERTIFICATE="$CERTIFICATE$line\n"
        fi
    done

    echo -e "${COLOR_YELLOW}${LANG[CERT_CONFIRM]}${COLOR_RESET}"
    read confirm
    echo

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    cat > docker-compose.yml <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

services:
    caddy:
      image: caddy:2.11.2
      container_name: caddy-remnawave
      hostname: caddy-remnawave
      <<: [*common, *logging]
      network_mode: host
      volumes:
          - ./Caddyfile:/etc/caddy/Caddyfile
          - /var/www/html:/var/www/html:ro
          - /dev/shm:/dev/shm:rw
          - caddy_data:/data
      command: sh -c 'rm -f /dev/shm/nginx.sock && caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'
      environment:
          - CADDY_SOCKET_PATH=/dev/shm/nginx.sock
          - SELF_STEAL_DOMAIN=${SELFSTEAL_DOMAIN}
      healthcheck:
          test: ["CMD", "test", "-S", "/dev/shm/nginx.sock"]
          interval: 2s
          timeout: 5s
          retries: 15
          start_period: 5s

    remnanode:
      image: remnawave/node:latest
      container_name: remnanode
      hostname: remnanode
      <<: [*common, *logging]
      network_mode: host
      cap_add:
        - NET_ADMIN
      environment:
        - NODE_PORT=2222
        - SECRET_KEY=$(echo -e "$CERTIFICATE")
      volumes:
        - /dev/shm:/dev/shm:rw

volumes:
  caddy_data:
    name: caddy_data
    driver: local
    external: false
EOL

    cat > /opt/remnanode/Caddyfile <<EOL
{
    admin off
    servers {
        listener_wrappers {
            proxy_protocol
            tls
        }
    }
    auto_https disable_redirects
}

http://{\$SELF_STEAL_DOMAIN} {
    bind 0.0.0.0
    redir https://{\$SELF_STEAL_DOMAIN}{uri} permanent
}

https://{\$SELF_STEAL_DOMAIN} {
    bind unix/{\$CADDY_SOCKET_PATH}
    root * /var/www/html
    try_files {path} /index.html
    file_server
}

:80 {
    bind 0.0.0.0
    respond 204
}
EOL
}

installation_node_caddy() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_NODE]}${COLOR_RESET}"
    install_node_caddy

    # Открываем NODE_PORT только для IP панели. Если ufw не активен — предупреждаем.
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
        ufw allow from $PANEL_IP to any port 2222 > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
    else
        echo -e "${COLOR_RED}$(printf "${LANG[NODE_UFW_INACTIVE]}" "$PANEL_IP")${COLOR_RESET}"
    fi

    # Публичный IP этого (нод-) сервера — нужен, чтобы человек правильно завёл ноду в панели.
    local NODE_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    [ -z "$NODE_IP" ] && NODE_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    [ -z "$NODE_IP" ] && NODE_IP="<IP этого сервера>"

    echo -e ""
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[NODE_PREREQ_TITLE]}${COLOR_RESET}"
    printf  "${COLOR_WHITE}${LANG[NODE_PREREQ_1]}${COLOR_RESET}\n" "$NODE_IP"
    echo -e "${COLOR_WHITE}${LANG[NODE_PREREQ_2]}${COLOR_RESET}"
    printf  "${COLOR_WHITE}${LANG[NODE_PREREQ_3]}${COLOR_RESET}\n" "2222" "$PANEL_IP"
    printf  "${COLOR_WHITE}${LANG[NODE_PREREQ_4]}${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN" "$NODE_IP"
    echo -e "${COLOR_RED}${LANG[NODE_PREREQ_NOTE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e ""

    echo -e "${COLOR_YELLOW}${LANG[STARTING_NODE]}${COLOR_RESET}"
    sleep 3
    cd /opt/remnanode

    local node_up_log="${DIR_REMNAWAVE}node_up.log"
    if ! docker compose up -d > "$node_up_log" 2>&1; then
        echo -e "${COLOR_RED}${LANG[NODE_COMPOSE_FAILED]}${COLOR_RESET}"
        tail -n 20 "$node_up_log"
        if grep -qiE 'toomanyrequests|pull rate limit|rate limit|429 Too Many' "$node_up_log"; then
            echo -e "${COLOR_YELLOW}${LANG[DOCKER_RATE_LIMIT_HINT]}${COLOR_RESET}"
        fi
        exit 1
    fi

    randomhtml

    sleep 5
    local node_running
    node_running=$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null)
    if [ "$node_running" != "true" ]; then
        echo -e "${COLOR_RED}${LANG[NODE_CONTAINER_CRASH]}${COLOR_RESET}"
        docker logs --tail 20 remnanode 2>&1
        echo -e "${COLOR_YELLOW}${LANG[CHECK_CONFIG]}${COLOR_RESET}"
        exit 1
    fi

    printf "${COLOR_YELLOW}${LANG[NODE_CHECK]}${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN"
    local max_attempts=5
    local attempt=1
    local delay=15
    local serving=false

    while [ $attempt -le $max_attempts ]; do
        printf "${COLOR_YELLOW}${LANG[NODE_ATTEMPT]}${COLOR_RESET}\n" "$attempt" "$max_attempts"
        if curl -s --fail --max-time 10 "https://$SELFSTEAL_DOMAIN" | grep -q "html"; then
            serving=true
            break
        fi
        printf "${COLOR_RED}${LANG[NODE_UNAVAILABLE]}${COLOR_RESET}\n" "$attempt"
        [ $attempt -lt $max_attempts ] && sleep $delay
        attempt=$((attempt + 1))
    done

    if [ "$serving" = true ]; then
        echo -e "${COLOR_GREEN}${LANG[NODE_LAUNCHED]}${COLOR_RESET}"
        return 0
    fi

    local port443_busy=false
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | grep -q ':443 ' && port443_busy=true
    fi

    echo -e ""
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[NODE_WAITING_CONFIG_TITLE]}${COLOR_RESET}"
    if [ "$port443_busy" = true ]; then
        printf "${COLOR_YELLOW}${LANG[NODE_PORT_LISTEN_YES]}${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN"
    else
        echo -e "${COLOR_YELLOW}${LANG[NODE_WAITING_CONFIG_REASON]}${COLOR_RESET}"
    fi
    echo -e "${COLOR_WHITE}${LANG[NODE_WAITING_CHECK]}${COLOR_RESET}"
    printf  "${COLOR_WHITE}${LANG[NODE_PREREQ_1]}${COLOR_RESET}\n" "$NODE_IP"
    echo -e "${COLOR_WHITE}${LANG[NODE_PREREQ_2]}${COLOR_RESET}"
    printf  "${COLOR_WHITE}${LANG[NODE_PREREQ_3]}${COLOR_RESET}\n" "2222" "$PANEL_IP"
    printf  "${COLOR_WHITE}${LANG[NODE_PREREQ_4]}${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN" "$NODE_IP"
    printf  "${COLOR_GREEN}${LANG[NODE_RECHECK_HINT]}${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    return 0
}