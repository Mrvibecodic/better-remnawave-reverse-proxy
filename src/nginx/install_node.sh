#!/bin/bash
# Module: Install Node Only

install_node_nginx() {
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

SELFSTEAL_BASE_DOMAIN=$(extract_domain "$SELFSTEAL_DOMAIN")

unique_domains["$SELFSTEAL_BASE_DOMAIN"]=1

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
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOL
}

installation_node() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_NODE]}${COLOR_RESET}"
    sleep 1

    declare -A unique_domains
    install_node_nginx

    declare -A domains_to_check
    domains_to_check["$SELFSTEAL_DOMAIN"]=1

    handle_certificates domains_to_check "$CERT_METHOD" "$LETSENCRYPT_EMAIL" "/opt/remnanode"

    if [ -z "$CERT_METHOD" ]; then
        local base_domain=$(extract_domain "$SELFSTEAL_DOMAIN")
        if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
            CERT_METHOD="1"
        else
            CERT_METHOD="2"
        fi
    fi

    if [ "$CERT_METHOD" == "1" ]; then
        local base_domain=$(extract_domain "$SELFSTEAL_DOMAIN")
        NODE_CERT_DOMAIN="$base_domain"
    else
        NODE_CERT_DOMAIN="$SELFSTEAL_DOMAIN"
    fi

    cat >> /opt/remnanode/docker-compose.yml <<EOL
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'

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
EOL

cat > /opt/remnanode/nginx.conf <<EOL
server_names_hash_bucket_size 64;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name $SELFSTEAL_DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    ssl_reject_handshake on;
    return 444;
}
EOL

    # Открываем NODE_PORT только для IP панели. Если ufw не активен — предупреждаем,
    # т.к. иначе порт API ноды (2222) останется открыт всему интернету.
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
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
