#!/bin/bash
# Module: Remnawave API Functions
# better-fork: ошибки идут в stderr, успех — в stdout; каждая ошибка возвращает код != 0,
# чтобы вызывающий код мог остановиться, а не продолжать с пустыми значениями.

# Печать диагностики строго в stderr, чтобы не загрязнять значения, captured через $(...)
api_err() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}" >&2
}

make_api_request() {
    local method=$1
    local url=$2
    local token=$3
    local data=$4

    # Все запросы идут на localhost панели; XFF фиксируем как 127.0.0.1 (раньше сюда
    # попадал мусор вида "домен:порт"). Таймауты не дают команде висеть бесконечно.
    local headers=(
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: 127.0.0.1"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser"
    )

    if [ -n "$data" ]; then
        curl -s --connect-timeout 10 --max-time 60 -X "$method" "$url" "${headers[@]}" -d "$data"
    else
        curl -s --connect-timeout 10 --max-time 60 -X "$method" "$url" "${headers[@]}"
    fi
}


register_remnawave() {
    local domain_url=$1
    local username=$2
    local password=$3
    local token=$4

    # JSON собираем через jq, чтобы спецсимволы в пароле не ломали тело запроса.
    local register_data
    register_data=$(jq -n --arg u "$username" --arg p "$password" '{username:$u,password:$p}')
    local register_response=$(make_api_request "POST" "http://$domain_url/api/auth/register" "$token" "$register_data")

    if [ -z "$register_response" ]; then
        api_err "${LANG[ERROR_EMPTY_RESPONSE_REGISTER]}"
        return 1
    elif [[ "$register_response" == *"accessToken"* ]]; then
        echo "$register_response" | jq -r '.response.accessToken'
        return 0
    else
        api_err "${LANG[ERROR_REGISTER]}: $register_response"
        return 1
    fi
}

get_panel_token() {
    TOKEN_FILE="${DIR_REMNAWAVE}/token"
    local domain_url="127.0.0.1:3000"

    local auth_status=$(make_api_request "GET" "http://${domain_url}/api/auth/status" "")
    local oauth_enabled=false

    if [ -n "$auth_status" ]; then
        local github_enabled=$(echo "$auth_status" | jq -r '.response.authentication.oauth2.providers.github // false' 2>/dev/null)
        local yandex_enabled=$(echo "$auth_status" | jq -r '.response.authentication.oauth2.providers.yandex // false' 2>/dev/null)
        local pocketid_enabled=$(echo "$auth_status" | jq -r '.response.authentication.oauth2.providers.pocketid // false' 2>/dev/null)
        local telegram_enabled=$(echo "$auth_status" | jq -r '.response.authentication.tgAuth.enabled // false' 2>/dev/null)

        if [ "$github_enabled" = "true" ] || [ "$yandex_enabled" = "true" ] || \
           [ "$pocketid_enabled" = "true" ] || [ "$telegram_enabled" = "true" ]; then
            oauth_enabled=true
        fi
    fi

    if [ -f "$TOKEN_FILE" ]; then
        token=$(cat "$TOKEN_FILE")
        echo -e "${COLOR_YELLOW}${LANG[USING_SAVED_TOKEN]}${COLOR_RESET}" >&2
        local test_response=$(make_api_request "GET" "http://${domain_url}/api/config-profiles" "$token")

        if [ -z "$test_response" ] || ! echo "$test_response" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
            if echo "$test_response" | grep -q '"statusCode":401' || \
               echo "$test_response" | jq -e '.message | test("Unauthorized")' > /dev/null 2>&1; then
                api_err "${LANG[INVALID_SAVED_TOKEN]}"
            else
                api_err "${LANG[INVALID_SAVED_TOKEN]}: $test_response"
            fi
            token=""
        fi
    fi

    if [ -z "$token" ]; then
        if [ "$oauth_enabled" = true ]; then
            echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}" >&2
            echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}" >&2
            echo -e "${COLOR_YELLOW}${LANG[TELEGRAM_OAUTH_WARNING]}${COLOR_RESET}" >&2
            printf "${COLOR_YELLOW}${LANG[CREATE_API_TOKEN_INSTRUCTION]}${COLOR_RESET}\n" "$PANEL_DOMAIN" >&2
            reading "${LANG[ENTER_API_TOKEN]}" token
            if [ -z "$token" ]; then
                api_err "${LANG[EMPTY_TOKEN_ERROR]}"
                return 1
            fi

            local test_response=$(make_api_request "GET" "http://${domain_url}/api/config-profiles" "$token")
            if [ -z "$test_response" ] || ! echo "$test_response" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
                api_err "${LANG[INVALID_SAVED_TOKEN]}: $test_response"
                return 1
            fi
        else
            reading "${LANG[ENTER_PANEL_USERNAME]}" username
            reading "${LANG[ENTER_PANEL_PASSWORD]}" password

            local login_data
            login_data=$(jq -n --arg u "$username" --arg p "$password" '{username:$u,password:$p}')
            local login_response=$(make_api_request "POST" "http://${domain_url}/api/auth/login" "" "$login_data")
            token=$(echo "$login_response" | jq -r '.response.accessToken // .accessToken // ""')
            if [ -z "$token" ] || [ "$token" == "null" ]; then
                api_err "${LANG[ERROR_TOKEN]}: $login_response"
                return 1
            fi
        fi

        echo "$token" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE" 2>/dev/null
        echo -e "${COLOR_GREEN}${LANG[TOKEN_RECEIVED_AND_SAVED]}${COLOR_RESET}" >&2
    else
        echo -e "${COLOR_GREEN}${LANG[TOKEN_USED_SUCCESSFULLY]}${COLOR_RESET}" >&2
    fi

    local final_test_response=$(make_api_request "GET" "http://${domain_url}/api/config-profiles" "$token")
    if [ -z "$final_test_response" ] || ! echo "$final_test_response" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
        api_err "${LANG[INVALID_SAVED_TOKEN]}: $final_test_response"
        return 1
    fi
    return 0
}

get_public_key() {
    local domain_url=$1
    local token=$2
    local target_dir=$3

    local api_response=$(make_api_request "GET" "http://$domain_url/api/keygen" "$token")

    if [ -z "$api_response" ]; then
        api_err "${LANG[ERROR_PUBLIC_KEY]}"
        return 1
    fi

    local pubkey=$(echo "$api_response" | jq -r '.response.pubKey')
    if [ -z "$pubkey" ] || [ "$pubkey" = "null" ]; then
        api_err "${LANG[ERROR_EXTRACT_PUBLIC_KEY]}: $api_response"
        return 1
    fi

    sed -i "s|SECRET_KEY=\"PUBLIC KEY FROM REMNAWAVE-PANEL\"|SECRET_KEY=\"$pubkey\"|g" "$target_dir/docker-compose.yml"

    echo -e "${COLOR_GREEN}${LANG[PUBLIC_KEY_SUCCESS]}${COLOR_RESET}" >&2
    return 0
}

generate_xray_keys() {
    local domain_url=$1
    local token=$2

    local api_response=$(make_api_request "GET" "http://$domain_url/api/system/tools/x25519/generate" "$token")

    if [ -z "$api_response" ]; then
        api_err "${LANG[ERROR_GENERATE_KEYS]}"
        return 1
    fi

    if echo "$api_response" | jq -e '.errorCode' > /dev/null 2>&1; then
        local error_message=$(echo "$api_response" | jq -r '.message')
        api_err "${LANG[ERROR_GENERATE_KEYS]}: $error_message"
        return 1
    fi

    local private_key=$(echo "$api_response" | jq -r '.response.keypairs[0].privateKey')

    if [ -z "$private_key" ] || [ "$private_key" = "null" ]; then
        api_err "${LANG[ERROR_EXTRACT_PRIVATE_KEY]}: $api_response"
        return 1
    fi

    echo "$private_key"
    return 0
}

check_node_domain() {
    local domain_url="$1"
    local token="$2"
    local domain="$3"

    local response=$(make_api_request "GET" "http://$domain_url/api/nodes" "$token")

    if [ -z "$response" ]; then
        api_err "${LANG[ERROR_CHECK_DOMAIN]}"
        return 1
    fi

    if echo "$response" | jq -e '.response' > /dev/null 2>&1; then
        local existing_domain=$(echo "$response" | jq -r --arg addr "$domain" '.response[] | select(.address == $addr) | .address' 2>/dev/null)
        if [ -n "$existing_domain" ]; then
            api_err "${LANG[DOMAIN_ALREADY_EXISTS]}: $domain"
            return 1
        fi
        return 0
    else
        local error_message=$(echo "$response" | jq -r '.message // "Unknown error"')
        api_err "${LANG[ERROR_CHECK_DOMAIN]}: $error_message"
        return 1
    fi
}

create_node() {
    local domain_url=$1
    local token=$2
    local config_profile_uuid=$3
    local inbound_uuid=$4
    local node_address="${5:-172.30.0.1}"
    local node_name="${6:-Steal}"

    local node_data=$(cat <<EOF
{
    "name": "$node_name",
    "address": "$node_address",
    "port": 2222,
    "configProfile": {
        "activeConfigProfileUuid": "$config_profile_uuid",
        "activeInbounds": ["$inbound_uuid"]
    },
    "isTrafficTrackingActive": false,
    "trafficLimitBytes": 0,
    "notifyPercent": 0,
    "trafficResetDay": 31,
    "excludedInbounds": [],
    "countryCode": "XX",
    "consumptionMultiplier": 1.0
}
EOF
)

    local node_response=$(make_api_request "POST" "http://$domain_url/api/nodes" "$token" "$node_data")

    if [ -z "$node_response" ]; then
        api_err "${LANG[ERROR_EMPTY_RESPONSE_NODE]}"
        return 1
    fi

    if echo "$node_response" | jq -e '.response.uuid' > /dev/null; then
        printf "${COLOR_GREEN}${LANG[NODE_CREATED]}${COLOR_RESET}\n" >&2
        return 0
    else
        api_err "${LANG[ERROR_CREATE_NODE]}: $node_response"
        return 1
    fi
}

get_config_profiles() {
    local domain_url="$1"
    local token="$2"

    local config_response=$(make_api_request "GET" "http://$domain_url/api/config-profiles" "$token")
    if [ -z "$config_response" ] || ! echo "$config_response" | jq -e '.' > /dev/null 2>&1; then
        api_err "${LANG[ERROR_NO_CONFIGS]}"
        return 1
    fi

    local profile_uuid=$(echo "$config_response" | jq -r '.response.configProfiles[] | select(.name == "Default-Profile") | .uuid' 2>/dev/null)
    if [ -z "$profile_uuid" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_DEFAULT_PROFILE]}${COLOR_RESET}" >&2
        return 0
    fi

    echo "$profile_uuid"
    return 0
}

delete_config_profile() {
    local domain_url="$1"
    local token="$2"
    local profile_uuid="$3"

    if [ -z "$profile_uuid" ]; then
        profile_uuid=$(get_config_profiles "$domain_url" "$token")
        if [ $? -ne 0 ] || [ -z "$profile_uuid" ]; then
            return 0
        fi
    fi

    local delete_response=$(make_api_request "DELETE" "http://$domain_url/api/config-profiles/$profile_uuid" "$token")
    if [ -z "$delete_response" ] || ! echo "$delete_response" | jq -e '.' > /dev/null 2>&1; then
        api_err "${LANG[ERROR_DELETE_PROFILE]}"
        return 1
    fi

    return 0
}

create_config_profile() {
    local domain_url=$1
    local token=$2
    local name=$3
    local domain=$4
    local private_key=$5
    local inbound_tag="${6:-Steal}"

    local short_id=$(openssl rand -hex 8)

    local request_body=$(jq -n --arg name "$name" --arg domain "$domain" --arg private_key "$private_key" --arg short_id "$short_id" --arg inbound_tag "$inbound_tag" '{
        name: $name,
        config: {
            log: { loglevel: "warning" },
            dns: {
                queryStrategy: "UseIPv4",
                servers: [{ address: "https://dns.google/dns-query", skipFallback: false }]
            },
            inbounds: [{
                tag: $inbound_tag,
                port: 443,
                protocol: "vless",
                settings: { clients: [], decryption: "none" },
                sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
                streamSettings: {
                    network: "tcp",
                    security: "reality",
                    realitySettings: {
                        show: false,
                        xver: 1,
                        dest: "/dev/shm/nginx.sock",
                        spiderX: "",
                        shortIds: [$short_id],
                        privateKey: $private_key,
                        serverNames: [$domain]
                    }
                }
            }],
            outbounds: [
                { tag: "DIRECT", protocol: "freedom" },
                { tag: "BLOCK", protocol: "blackhole" }
            ],
            routing: {
                rules: [
                    { ip: ["geoip:private"], outboundTag: "BLOCK" },
                    { protocol: ["bittorrent"], outboundTag: "BLOCK" }
                ]
            }
        }
    }')

    local response=$(make_api_request "POST" "http://$domain_url/api/config-profiles" "$token" "$request_body")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' > /dev/null; then
        api_err "${LANG[ERROR_CREATE_CONFIG_PROFILE]}: $response"
        return 1
    fi

    local config_uuid=$(echo "$response" | jq -r '.response.uuid')
    local inbound_uuid=$(echo "$response" | jq -r '.response.inbounds[0].uuid')
    if [ -z "$config_uuid" ] || [ "$config_uuid" = "null" ] || [ -z "$inbound_uuid" ] || [ "$inbound_uuid" = "null" ]; then
        api_err "${LANG[ERROR_CREATE_CONFIG_PROFILE]}: Invalid UUIDs in response: $response"
        return 1
    fi

    echo "$config_uuid $inbound_uuid"
    return 0
}

create_host() {
    local domain_url=$1
    local token=$2
    local inbound_uuid=$3
    local address=$4
    local config_uuid=$5
    local host_remark="${6:-Steal}"

    local request_body=$(jq -n --arg config_uuid "$config_uuid" --arg inbound_uuid "$inbound_uuid" --arg remark "$host_remark" --arg address "$address" '{
        inbound: {
            configProfileUuid: $config_uuid,
            configProfileInboundUuid: $inbound_uuid
        },
        remark: $remark,
        address: $address,
        port: 443,
        path: "",
        sni: $address,
        host: "",
        alpn: null,
        fingerprint: "chrome",
        allowInsecure: false,
        isDisabled: false,
        securityLayer: "DEFAULT"
    }')

    local response=$(make_api_request "POST" "http://$domain_url/api/hosts" "$token" "$request_body")

    if [ -z "$response" ]; then
        api_err "${LANG[ERROR_EMPTY_RESPONSE_HOST]}"
        return 1
    fi

    if echo "$response" | jq -e '.response.uuid' > /dev/null; then
        echo -e "${COLOR_GREEN}${LANG[HOST_CREATED]}${COLOR_RESET}" >&2
        return 0
    else
        api_err "${LANG[ERROR_CREATE_HOST]}: $response"
        return 1
    fi
}

get_default_squad() {
    local domain_url=$1
    local token=$2

    local response=$(make_api_request "GET" "http://$domain_url/api/internal-squads" "$token")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.internalSquads' > /dev/null 2>&1; then
        api_err "${LANG[ERROR_GET_SQUAD]}: $response"
        return 1
    fi

    local squad_uuids=$(echo "$response" | jq -r '.response.internalSquads[].uuid' 2>/dev/null)
    if [ -z "$squad_uuids" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_SQUADS_FOUND]}${COLOR_RESET}" >&2
        return 0
    fi

    local valid_uuids=""
    while IFS= read -r uuid; do
        if [ -z "$uuid" ]; then
            continue
        fi
        if [[ $uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            valid_uuids+="$uuid\n"
        else
            api_err "${LANG[INVALID_UUID_FORMAT]}: $uuid"
        fi
    done <<< "$squad_uuids"

    if [ -z "$valid_uuids" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_VALID_SQUADS_FOUND]}${COLOR_RESET}" >&2
        return 0
    fi

    echo -e "$valid_uuids" | sed '/^$/d'
    return 0
}

update_squad() {
    local domain_url=$1
    local token=$2
    local squad_uuid=$3
    local inbound_uuid=$4

    if [[ ! $squad_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        api_err "${LANG[INVALID_SQUAD_UUID]}: $squad_uuid"
        return 1
    fi

    if [[ ! $inbound_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        api_err "${LANG[INVALID_INBOUND_UUID]}: $inbound_uuid"
        return 1
    fi

    local squad_response=$(make_api_request "GET" "http://$domain_url/api/internal-squads" "$token")
    if [ -z "$squad_response" ] || ! echo "$squad_response" | jq -e '.response.internalSquads' > /dev/null 2>&1; then
        api_err "${LANG[ERROR_GET_SQUAD]}: $squad_response"
        return 1
    fi

    local existing_inbounds=$(echo "$squad_response" | jq -r --arg uuid "$squad_uuid" '.response.internalSquads[] | select(.uuid == $uuid) | .inbounds[].uuid' 2>/dev/null)
    if [ -z "$existing_inbounds" ]; then
        existing_inbounds="[]"
    else
        existing_inbounds=$(echo "$existing_inbounds" | jq -R . | jq -s .)
    fi

    local inbounds_array=$(jq -n --argjson existing "$existing_inbounds" --arg new "$inbound_uuid" '$existing + [$new] | unique')

    local request_body=$(jq -n --arg uuid "$squad_uuid" --argjson inbounds "$inbounds_array" '{
        uuid: $uuid,
        inbounds: $inbounds
    }')

    local response=$(make_api_request "PATCH" "http://$domain_url/api/internal-squads" "$token" "$request_body")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' > /dev/null 2>&1; then
        api_err "${LANG[ERROR_UPDATE_SQUAD]}: $response"
        return 1
    fi

    return 0
}

create_api_token() {
    local domain_url=$1
    local token=$2
    local target_dir=$3
    local token_name="${4:-subscription-page}"

    # better-fork: панель Remnawave 2.8+ сменила тело POST /api/tokens — теперь ОБЯЗАТЕЛЬНЫ
    # name (string 2..30) и expiresInDays (number >=1); поля tokenName больше нет, из-за чего
    # старый запрос падал с "Validation failed" и токен для subscription-page не создавался.
    # scopes опциональны (дефолт ["*"] = полный доступ). Суффикс — чтобы имя не конфликтовало
    # при переустановке. expiresInDays=3650 (~10 лет).
    local api_name
    api_name="$(printf '%.20s' "$token_name")-$(openssl rand -hex 3)"
    local token_data
    token_data=$(jq -n --arg n "$api_name" '{name: $n, expiresInDays: 3650}')
    local api_response
    api_response=$(make_api_request "POST" "http://$domain_url/api/tokens" "$token" "$token_data")

    if [ -z "$api_response" ]; then
        api_err "${LANG[ERROR_CREATE_API_TOKEN]}"
        return 1
    fi

    local api_token
    api_token=$(echo "$api_response" | jq -r '.response.token')

    if [ -z "$api_token" ] || [ "$api_token" = "null" ]; then
        api_err "${LANG[ERROR_CREATE_API_TOKEN]}: $(echo "$api_response" | jq -r '.message // "Unknown error"')"
        return 1
    fi

    sed -i "s|REMNAWAVE_API_TOKEN=.*|REMNAWAVE_API_TOKEN=$api_token|" "$target_dir/docker-compose.yml"
    chmod 600 "$target_dir/docker-compose.yml" 2>/dev/null

    sleep 1

    echo -e "${COLOR_GREEN}${LANG[API_TOKEN_ADDED]}${COLOR_RESET}" >&2
    return 0
}
