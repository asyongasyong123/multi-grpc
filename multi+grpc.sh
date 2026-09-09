#!/bin/bash
set -euo pipefail

# ===================================================
# 🚀 GCP-XRAY MULTI-ENGINE DEPLOYER (4 ENGINES + gRPC)
# ✅ ENGINES: OPENRESTY, ENVOY, HAPROXY, CADDY
# ✅ PROTOCOLS: TROJAN (WS/gRPC), VLESS (WS/gRPC)
# ===================================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

if ! command -v jq &> /dev/null; then
  echo -e "\n${YELLOW}⚠️ Installing required tool: jq...${NC}"
  sudo apt update -qq && sudo apt install -y -qq jq || {
    echo -e "${RED}❌ Failed to install jq!${NC}"
    exit 1
  }
  echo -e "${GREEN}✅ jq installed successfully!${NC}"
fi

list_deployed_services() {
  echo -e "\n======================================"
  echo -e "${CYAN}📋 ALL DEPLOYED GCP-XRAY SERVICES${NC}"
  echo -e "======================================"
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  echo "Project: $PROJECT_ID"
  echo ""

  SERVICES=$(gcloud run services list \
    --format="value(metadata.name, status.url, region, metadata.creationTimestamp.date(%Y-%m-%d))" \
    --project="$PROJECT_ID" 2>/dev/null)

  if [ -z "$SERVICES" ]; then
    echo -e "${RED}❌ No services found.${NC}"
  else
    local COUNT=1
    while IFS=$'\t' read -r NAME URL REGION CREATED; do
      [ -z "$NAME" ] && continue
      echo -e "${GREEN}=== SERVICE #$COUNT ===${NC}"
      echo "🔹 Name:    $NAME"
      echo "🔹 URL:     $URL"
      echo "🔹 Region:  $REGION"
      echo "🔹 Created: $CREATED"
      echo ""
      ((COUNT++))
    done <<< "$SERVICES"
  fi
  read -p "Press [Enter] to return..." </dev/tty
}

select_region() {
  echo -e "\n=== GCP CLOUD RUN REGION ==="
  echo "1) us-central1      (Iowa, US 🇺🇸)"
  echo "2) us-east1         (South Carolina, US 🇺🇸)"
  echo "3) asia-east1       (Taiwan 🇹🇼 — RECOMMENDED!)"
  echo "4) asia-southeast1  (Singapore 🇸🇬)"
  echo "5) asia-northeast1  (Tokyo, Japan 🇯🇵)"
  echo "0) Custom region code"
  echo ""
  read -p "Enter region number: " REGION_NUM </dev/tty

  case $REGION_NUM in
    1) REGION="us-central1" ;;
    2) REGION="us-east1" ;;
    3) REGION="asia-east1" ;;
    4) REGION="asia-southeast1" ;;
    5) REGION="asia-northeast1" ;;
    0) read -p "Type full region code: " REGION </dev/tty ;;
    *) REGION="asia-east1" ;;
  esac
}

deploy_new_service() {
  select_region

  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  if [ -z "$PROJECT_ID" ]; then
      echo -e "${RED}❌ No project set! Run: gcloud config set project YOUR_ID${NC}"
      read -p "Press [Enter] to return..." </dev/tty
      return
  fi

  gcloud services enable run.googleapis.com cloudbuild.googleapis.com --project="$PROJECT_ID" --quiet

  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}          CHOOSE PROXY ENGINE${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo "1) OpenResty          - Standard / Reliable ✅"
  echo "2) Envoy Proxy        - High Performance"
  echo "3) HAProxy            - Lightweight / Low Latency"
  echo "4) Caddy Server       - Modern / Auto HTTP/2 & gRPC ⭐"
  while true; do
      read -p "Select Engine [1-4]: " ENGINE_CHOICE </dev/tty
      case $ENGINE_CHOICE in
          1) ENGINE="openresty"; DISPLAY_ENGINE="OpenResty"; break ;;
          2) ENGINE="envoy"; DISPLAY_ENGINE="Envoy"; break ;;
          3) ENGINE="haproxy"; DISPLAY_ENGINE="HAProxy"; break ;;
          4) ENGINE="caddy"; DISPLAY_ENGINE="Caddy"; break ;;
          *) echo -e "${RED}Enter 1, 2, 3, or 4 only${NC}" ;;
      esac
  done

  SUFFIX=$(openssl rand -hex 3)
  CLOUD_RUN_SERVICE_NAME="gcp-xray-${ENGINE}-${SUFFIX}"

  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"' EXIT

  MEMORY="2Gi"
  CPU="2"
  CONCURRENCY="1000"
  TIMEOUT="3600"
  MIN_INST="0"
  MAX_INST="1"

  cd "$BUILD_DIR" || exit 1

  # XRay Config with WS (10001, 10002) and gRPC (10003, 10004)
  cat > config.json <<'EOF'
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["8.8.8.8", "8.8.4.4"], "strategy": "UseIPv4" },
  "policy": { "levels": { "0": { "handshake": 2, "connIdle": 3600, "bufferSize": 1048576 } } },
  "inbounds": [
    {
      "tag": "trojan-ws", "port": 10001, "listen": "127.0.0.1", "protocol": "trojan",
      "settings": { "clients": [{"password": "gcp-xray", "level": 0}] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } }
    },
    {
      "tag": "vless-ws", "port": 10002, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567", "level": 0}], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" } }
    },
    {
      "tag": "trojan-grpc", "port": 10003, "listen": "127.0.0.1", "protocol": "trojan",
      "settings": { "clients": [{"password": "gcp-xray", "level": 0}] },
      "streamSettings": { "network": "grpc", "grpcSettings": { "serviceName": "trojan-grpc" } }
    },
    {
      "tag": "vless-grpc", "port": 10004, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567", "level": 0}], "decryption": "none" },
      "streamSettings": { "network": "grpc", "grpcSettings": { "serviceName": "vless-grpc" } }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF

  DECOY_HTML="<!DOCTYPE html><html><head><title>System Status</title><style>body{font-family:sans-serif;background:#0d1117;color:#c9d1d9;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;text-align:center;}h1{color:#58a6ff;font-size:24px;}p{color:#8b949e;}</style></head><body><div><h1>Welcome to my ${DISPLAY_ENGINE} cloud application gateway.</h1><p>Everything is operational.</p></div></body></html>"

  if [ "$ENGINE" = "openresty" ]; then
    cat > nginx.conf <<EOF
worker_processes auto;
events { worker_connections 4096; }
http {
  include mime.types;
  default_type text/html;
  server {
    listen 8080;
    http2 on;

    location /health { return 200 "OK\n"; add_header Content-Type text/plain; }
    location / {
      default_type text/html;
      return 200 "${DECOY_HTML}";
    }
    location /trojan-ws {
      proxy_pass http://127.0.0.1:10001;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host;
    }
    location /vless-ws {
      proxy_pass http://127.0.0.1:10002;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host;
    }
    location /trojan-grpc {
      grpc_pass grpc://127.0.0.1:10003;
      grpc_set_header Host \$host;
    }
    location /vless-grpc {
      grpc_pass grpc://127.0.0.1:10004;
      grpc_set_header Host \$host;
    }
  }
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
/usr/local/bin/xray run -c /etc/xray.json &
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
EOF
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray geosite.dat geoip.dat && chmod +x xray
FROM openresty/openresty:alpine-fat
COPY --from=builder /xray /usr/local/bin/xray
COPY --from=builder /geosite.dat /usr/local/share/xray/
COPY --from=builder /geoip.dat /usr/local/share/xray/
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "envoy" ]; then
    cat > envoy.yaml <<EOF
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address: { address: 0.0.0.0, port_value: 8080 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          codec_type: AUTO
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match: { prefix: "/health" }
                direct_response: { status: 200, body: { inline_string: "OK\n" } }
              - match: { prefix: "/trojan-ws" }
                route: { cluster: trojan_ws_cluster, timeout: 3600s, upgrade_configs: [{ upgrade_type: "websocket" }] }
              - match: { prefix: "/vless-ws" }
                route: { cluster: vless_ws_cluster, timeout: 3600s, upgrade_configs: [{ upgrade_type: "websocket" }] }
              - match: { prefix: "/trojan-grpc" }
                route: { cluster: trojan_grpc_cluster, timeout: 0s }
              - match: { prefix: "/vless-grpc" }
                route: { cluster: vless_grpc_cluster, timeout: 0s }
              - match: { prefix: "/" }
                direct_response:
                  status: 200
                  body: { inline_string: "${DECOY_HTML}" }
                response_headers_to_add:
                - header: { key: "content-type", value: "text/html; charset=utf-8" }
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: trojan_ws_cluster
    connect_timeout: 10s
    type: STATIC
    load_assignment:
      cluster_name: trojan_ws_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10001 } } } }] }]
  - name: vless_ws_cluster
    connect_timeout: 10s
    type: STATIC
    load_assignment:
      cluster_name: vless_ws_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10002 } } } }] }]
  - name: trojan_grpc_cluster
    connect_timeout: 10s
    type: STATIC
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options: {}
    load_assignment:
      cluster_name: trojan_grpc_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10003 } } } }] }]
  - name: vless_grpc_cluster
    connect_timeout: 10s
    type: STATIC
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options: {}
    load_assignment:
      cluster_name: vless_grpc_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10004 } } } }] }]
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
/usr/local/bin/xray run -c /etc/xray.json &
exec envoy -c /etc/envoy.yaml
EOF
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray geosite.dat geoip.dat && chmod +x xray
FROM envoyproxy/envoy:v1.30-latest
COPY --from=builder /xray /usr/local/bin/xray
COPY --from=builder /geosite.dat /usr/local/share/xray/
COPY --from=builder /geoip.dat /usr/local/share/xray/
COPY config.json /etc/xray.json
COPY envoy.yaml /etc/envoy.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "haproxy" ]; then
    cat > haproxy.cfg <<EOF
global
    log stdout format raw local0
    maxconn 10000

defaults
    log global
    mode http
    timeout connect 10s
    timeout client 3600s
    timeout server 3600s
    timeout tunnel 3600s

frontend main
    bind *:8080 proto h2,http/1.1
    acl is_health path /health
    acl is_trojan_ws path_beg /trojan-ws
    acl is_vless_ws path_beg /vless-ws
    acl is_trojan_grpc path_beg /trojan-grpc
    acl is_vless_grpc path_beg /vless-grpc

    use_backend health_backend if is_health
    use_backend trojan_ws_backend if is_trojan_ws
    use_backend vless_ws_backend if is_vless_ws
    use_backend trojan_grpc_backend if is_trojan_grpc
    use_backend vless_grpc_backend if is_vless_grpc
    default_backend default_backend

backend health_backend
    http-request return status 200 content-type "text/plain" string "OK\n"

backend default_backend
    http-request return status 200 content-type "text/html" string "${DECOY_HTML}"

backend trojan_ws_backend
    server xray1 127.0.0.1:10001 check

backend vless_ws_backend
    server xray2 127.0.0.1:10002 check

backend trojan_grpc_backend
    server xray3 127.0.0.1:10003 check proto h2

backend vless_grpc_backend
    server xray4 127.0.0.1:10004 check proto h2
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
/usr/local/bin/xray run -c /etc/xray.json &
exec haproxy -f /usr/local/etc/haproxy/haproxy.cfg -db
EOF
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray geosite.dat geoip.dat && chmod +x xray
FROM haproxy:2.8-alpine
COPY --from=builder /xray /usr/local/bin/xray
COPY --from=builder /geosite.dat /usr/local/share/xray/
COPY --from=builder /geoip.dat /usr/local/share/xray/
COPY config.json /etc/xray.json
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY entrypoint.sh /entrypoint.sh
USER root
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "caddy" ]; then
    cat > Caddyfile <<EOF
{
    admin off
    auto_https off
}

:8080 {
    @health path /health
    handle @health {
        respond "OK\n" 200
    }

    @trojan_ws path /trojan-ws*
    handle @trojan_ws {
        reverse_proxy 127.0.0.1:10001
    }

    @vless_ws path /vless-ws*
    handle @vless_ws {
        reverse_proxy 127.0.0.1:10002
    }

    @trojan_grpc path /trojan-grpc*
    handle @trojan_grpc {
        reverse_proxy h2c://127.0.0.1:10003
    }

    @vless_grpc path /vless-grpc*
    handle @vless_grpc {
        reverse_proxy h2c://127.0.0.1:10004
    }

    handle {
        header Content-Type "text/html; charset=utf-8"
        respond "${DECOY_HTML}" 200
    }
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
/usr/local/bin/xray run -c /etc/xray.json &
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
EOF
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray geosite.dat geoip.dat && chmod +x xray
FROM caddy:2-alpine
COPY --from=builder /xray /usr/local/bin/xray
COPY --from=builder /geosite.dat /usr/local/share/xray/
COPY --from=builder /geoip.dat /usr/local/share/xray/
COPY config.json /etc/xray.json
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh
USER root
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF
  fi

  chmod +x entrypoint.sh
  IMAGE="gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME:latest"

  echo -e "\n${CYAN}🔨 Building image ($ENGINE engine)...${NC}"
  gcloud builds submit --project="$PROJECT_ID" --tag "$IMAGE" . --quiet

  echo -e "\n${CYAN}🚀 Deploying to Cloud Run...${NC}"
  gcloud run deploy "$CLOUD_RUN_SERVICE_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --image="$IMAGE" \
    --memory="$MEMORY" \
    --cpu="$CPU" \
    --concurrency="$CONCURRENCY" \
    --timeout="$TIMEOUT" \
    --min-instances="$MIN_INST" \
    --max-instances="$MAX_INST" \
    --allow-unauthenticated \
    --port 8080 \
    --use-http2 \
    --session-affinity \
    --execution-environment gen2 --no-cpu-throttling --cpu-boost --quiet

  CLOUD_RUN_URL=$(gcloud run services describe "$CLOUD_RUN_SERVICE_NAME" --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')
  DOMAIN=$(echo "$CLOUD_RUN_URL" | sed 's|https://||')

  TROJAN_WS_LINK="trojan://gcp-xray@firebaseremoteconfigrealtime.googleapis.com:443?type=ws&host=${DOMAIN}&headerType=none&path=%2Ftrojan-ws&security=tls&sni=firebaseremoteconfigrealtime.googleapis.com#${CLOUD_RUN_SERVICE_NAME}-Trojan-WS"
  VLESS_WS_LINK="vless://a1b2c3d4-5678-40ef-98ab-cdef01234567@firebaseremoteconfigrealtime.googleapis.com:443?encryption=none&type=ws&host=${DOMAIN}&headerType=none&path=%2Fvless-ws&security=tls&sni=firebaseremoteconfigrealtime.googleapis.com#${CLOUD_RUN_SERVICE_NAME}-VLESS-WS"
  TROJAN_GRPC_LINK="trojan://gcp-xray@firebaseremoteconfigrealtime.googleapis.com:443?type=grpc&serviceName=trojan-grpc&host=${DOMAIN}&security=tls&sni=firebaseremoteconfigrealtime.googleapis.com#${CLOUD_RUN_SERVICE_NAME}-Trojan-gRPC"
  VLESS_GRPC_LINK="vless://a1b2c3d4-5678-40ef-98ab-cdef01234567@firebaseremoteconfigrealtime.googleapis.com:443?encryption=none&type=grpc&serviceName=vless-grpc&host=${DOMAIN}&security=tls&sni=firebaseremoteconfigrealtime.googleapis.com#${CLOUD_RUN_SERVICE_NAME}-VLESS-gRPC"

  clear
  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}✅ DEPLOYMENT SUCCESS! (${DISPLAY_ENGINE})${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}🌐 DOMAIN:${NC} $DOMAIN"
  echo ""
  echo -e "${GREEN}🔹 TROJAN (WS):${NC}\n$TROJAN_WS_LINK\n"
  echo -e "${GREEN}🔹 VLESS (WS):${NC}\n$VLESS_WS_LINK\n"
  echo -e "${GREEN}🔹 TROJAN (gRPC):${NC}\n$TROJAN_GRPC_LINK\n"
  echo -e "${GREEN}🔹 VLESS (gRPC):${NC}\n$VLESS_GRPC_LINK"
  echo -e "${CYAN}=========================================${NC}"

  read -p $'\nPress [Enter] to return...' </dev/tty
}

while true; do
  clear
  echo "======================================"
  echo "    GCP-XRAY DEPLOYER MENU    "
  echo "======================================"
  echo "1) Deploy New GCP-XRAY Service"
  echo "2) List All Services"
  echo "3) Exit"
  echo "======================================"
  read -p "Select Option [1-3]: " MENU_CHOICE </dev/tty

  case $MENU_CHOICE in
    1) deploy_new_service ;;
    2) list_deployed_services ;;
    3) exit 0 ;;
    *) echo -e "${RED}Invalid!${NC}"; sleep 1 ;;
  esac
done
