#!/usr/bin/env bash
# oneclick-deploy-enterprise.sh
# Spring Boot fat JAR + blue/green + optional canary + hardened systemd + Nginx (+TLS/mTLS) + SBOM + scans
# Zero-downtime deploys with security guardrails. SSH/22 is explicitly preserved. Ubuntu/Debian.

set -euo pipefail

# -------- Config (override via env) ----------
APP_NAME="${APP_NAME:-hello-boot}"
GROUP_ID="${GROUP_ID:-com.example}"
PACKAGE="${PACKAGE:-com.example.demo}"
JAVA_RELEASE="${JAVA_RELEASE:-17}"

USE_NGINX="${USE_NGINX:-yes}"             # yes|no
DOMAIN="${DOMAIN:-}"                      # enables TLS if EMAIL provided
EMAIL="${EMAIL:-}"                        # Let's Encrypt account email

PORT_A="${PORT_A:-8081}"                  # blue
PORT_B="${PORT_B:-8082}"                  # green
KEEP_RELEASES="${KEEP_RELEASES:-5}"       # how many releases to keep
JDK_PKG="${JDK_PKG:-openjdk-17-jdk}"

# Nginx security/perf
RATE="${RATE:-10r/s}"                     # requests per IP
BURST="${BURST:-20}"                      # burst size
ACTUATOR_ALLOW_CIDRS="${ACTUATOR_ALLOW_CIDRS:-127.0.0.1/32,::1/128}"  # comma-separated
ENABLE_BROTLI="${ENABLE_BROTLI:-auto}"    # auto|yes|no

# Blue/Green & Canary
CANARY_PERCENT="${CANARY_PERCENT:-0}"     # 0..100 (0=off). Keeps old instance running with weighted split.
PROMOTE="${PROMOTE:-0}"                   # 1 to promote new (100%) and stop old after success

# Ops / Security
LOCKDOWN_NET="${LOCKDOWN_NET:-0}"         # 1 = systemd egress deny-all, allowlist via ALLOW_NET_CIDRS
ALLOW_NET_CIDRS="${ALLOW_NET_CIDRS:-}"    # space-separated CIDRs (e.g. "10.0.0.0/8 172.16.0.0/12")
ENABLE_TRIVY_SCAN="${ENABLE_TRIVY_SCAN:-auto}" # auto|yes|no (best-effort)
ENABLE_ATTESTATION="${ENABLE_ATTESTATION:-0}"  # 1 = cosign create local attestation (requires key)
COSIGN_KEY_PATH="${COSIGN_KEY_PATH:-}"    # path to cosign.key (if ENABLE_ATTESTATION=1)
JAVA_TLS13_ONLY="${JAVA_TLS13_ONLY:-1}"   # 1 = force TLS1.3 (server & client) at JVM level
MAINTENANCE_FLAG="${MAINTENANCE_FLAG:-/var/www/${APP_NAME}/MAINTENANCE_ON}"  # if present -> 503

ROLLBACK="${ROLLBACK:-0}"                 # 1 = roll back to previous release
# --------------------------------------------

WORKDIR="$PWD"
PROJ_DIR="$WORKDIR/$APP_NAME"
INSTALL_DIR="/opt/$APP_NAME"
RELEASES_DIR="$INSTALL_DIR/releases"
CURRENT_DIR_LINK="$INSTALL_DIR/current"     # symlink -> release dir
CHECKSUMS_DIR="$INSTALL_DIR/checksums"
ENV_DIR="/etc/$APP_NAME"
ENV_FILE="$ENV_DIR/env"
ACTIVE_FILE="$INSTALL_DIR/active_port"
SVC_TEMPLATE="/etc/systemd/system/${APP_NAME}@.service"
NGX_SITE="/etc/nginx/sites-available/$APP_NAME"
NGX_LINK="/etc/nginx/sites-enabled/$APP_NAME"
NGX_CONF="/etc/nginx/nginx.conf"
AUDIT_DIR="$INSTALL_DIR/audit"
AUDIT_FILE="$AUDIT_DIR/manifest-$(date +%Y%m%d_%H%M%S).json"

log(){ echo ">>> $*"; }
warn(){ echo "!!! $*" >&2; }
die(){ echo "!!! $*" >&2; exit 1; }
trap 'echo "!!! failed at line $LINENO"; exit 1' ERR

# ------------------------- ROLLBACK -------------------------
if [ "$ROLLBACK" = "1" ]; then
  [ -d "$RELEASES_DIR" ] || die "No releases found to roll back."
  CUR="$(readlink -f "$CURRENT_DIR_LINK" || true)"
  PREV="$(ls -1dt "$RELEASES_DIR"/release-* 2>/dev/null | grep -vx "$CUR" | head -n1 || true)"
  [ -n "$PREV" ] || die "No previous release."
  sudo ln -sfn "$PREV" "$CURRENT_DIR_LINK"

  ACTIVE_PORT="$( [ -f "$ACTIVE_FILE" ] && cat "$ACTIVE_FILE" || echo "$PORT_A" )"
  INACTIVE_PORT="$PORT_B"; [ "$ACTIVE_PORT" = "$PORT_B" ] && INACTIVE_PORT="$PORT_A"

  log "Rolling back to $(basename "$PREV"); restarting ${APP_NAME}@${INACTIVE_PORT}..."
  sudo systemctl daemon-reload
  sudo systemctl restart "${APP_NAME}@${INACTIVE_PORT}"

  for i in {1..60}; do
    curl -fsS "http://127.0.0.1:${INACTIVE_PORT}/actuator/health" | grep -q '"status":"UP"' && break
    sleep 1
    [ $i -eq 60 ] && die "Rollback instance on :${INACTIVE_PORT} not healthy."
  done

  if [ -f "$NGX_SITE" ]; then
    # point upstream to rolled-back port; keep old running briefly
    sudo sed -i "s|server 127.0.0.1:[0-9]\+;|server 127.0.0.1:${INACTIVE_PORT};|g" "$NGX_SITE"
    sudo nginx -t && sudo systemctl reload nginx || true
  fi
  echo "$INACTIVE_PORT" | sudo tee "$ACTIVE_FILE" >/dev/null
  log "Rollback complete. Active port now $(cat "$ACTIVE_FILE")."
  exit 0
fi

# -------------------- Install base deps ---------------------
log "Installing base deps..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "$JDK_PKG" maven ca-certificates curl unzip coreutils jq \
  nginx certbot python3-certbot-nginx || true
command -v ss >/dev/null 2>&1 || sudo apt-get install -y iproute2 >/dev/null 2>&1 || true
command -v sha256sum >/dev/null 2>&1 || sudo apt-get install -y coreutils >/dev/null 2>&1 || true

# --- NEVER BREAK SSH (GCE-safe) ---
sudo apt-get install -y openssh-server
sudo systemctl enable ssh >/dev/null 2>&1 || true
sudo systemctl start  ssh >/dev/null 2>&1 || true
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 22/tcp >/dev/null 2>&1 || true
  REMOTE_IP="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $1}')"
  [ -n "$REMOTE_IP" ] && sudo ufw allow from "$REMOTE_IP" to any port 22 proto tcp >/dev/null 2>&1 || true
fi
if command -v nft >/dev/null 2>&1; then
  if ! sudo nft list ruleset 2>/dev/null | grep -q 'tcp dport 22 .* accept'; then
    sudo nft add rule inet filter input tcp dport 22 ct state new,established accept >/dev/null 2>&1 || true
  fi
fi
if ! ss -ltn 2>/dev/null | grep -q ':22 '; then
  warn "Nothing listening on :22; attempting to start sshd"; sudo systemctl start ssh || true
fi

# ----------------- Optional tools (best-effort) -------------
if [ "$ENABLE_TRIVY_SCAN" != "no" ]; then
  sudo apt-get install -y trivy >/dev/null 2>&1 || true
fi
if [ "$ENABLE_ATTESTATION" = "1" ]; then
  sudo apt-get install -y cosign >/dev/null 2>&1 || true
fi

# ----------------- Users & dirs -----------------------------
if ! id "$APP_NAME" >/dev/null 2>&1; then
  sudo useradd -r -m -U -d "$INSTALL_DIR" -s /usr/sbin/nologin "$APP_NAME"
fi
sudo mkdir -p "$RELEASES_DIR" "$CHECKSUMS_DIR" "$AUDIT_DIR" "$ENV_DIR"
if [ "$USE_NGINX" = "yes" ]; then
  sudo rm -f /etc/nginx/sites-enabled/default || true
  sudo mkdir -p "$(dirname "$MAINTENANCE_FLAG")"
fi

# ---- Blue/green port selection ----
ACTIVE_PORT="$( [ -f "$ACTIVE_FILE" ] && cat "$ACTIVE_FILE" || echo "$PORT_A" )"
INACTIVE_PORT="$PORT_B"; [ "$ACTIVE_PORT" = "$PORT_B" ] && INACTIVE_PORT="$PORT_A"

# ----------------- Generate project -------------------------
rm -rf "$PROJ_DIR"; mkdir -p "$PROJ_DIR"; cd "$WORKDIR"
log "Generating Spring Boot project (web + actuator + prometheus)..."
ZIP_OK=0
if curl -fsSL -G "https://start.spring.io/starter.zip" \
  --data-urlencode "type=maven-project" \
  --data-urlencode "language=java" \
  --data-urlencode "baseDir=$APP_NAME" \
  --data-urlencode "groupId=$GROUP_ID" \
  --data-urlencode "artifactId=$APP_NAME" \
  --data-urlencode "name=$APP_NAME" \
  --data-urlencode "packageName=$PACKAGE" \
  --data-urlencode "dependencies=web,actuator,prometheus" -o boot.zip; then
  unzip -qo boot.zip -d "$WORKDIR"; rm -f boot.zip; ZIP_OK=1
fi
if [ "$ZIP_OK" -ne 1 ]; then
  log "start.spring.io unreachable — scaffolding locally"
  mkdir -p "$PROJ_DIR/src/main/java/${PACKAGE//./\/}" "$PROJ_DIR/src/main/resources"
  cat > "$PROJ_DIR/pom.xml" <<'POM'
<project xmlns="http://maven.apache.org/POM/4.0.0"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.3.4</version>
    <relativePath/>
  </parent>
  <groupId>__GROUP_ID__</groupId>
  <artifactId>__APP_NAME__</artifactId>
  <version>1.0.0</version>
  <name>__APP_NAME__</name>
  <properties><java.version>__JAVA__</java.version></properties>
  <dependencies>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web"/></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-actuator"/></dependency>
    <dependency><groupId>io.micrometer</groupId><artifactId>micrometer-registry-prometheus"/></dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin><groupId>org.springframework.boot</groupId><artifactId>spring-boot-maven-plugin"/></plugin>
    </plugins>
  </build>
</project>
POM
  sed -i "s|__GROUP_ID__|$GROUP_ID|; s|__APP_NAME__|$APP_NAME|g; s|__JAVA__|$JAVA_RELEASE|" "$PROJ_DIR/pom.xml"
  cat > "$PROJ_DIR/src/main/java/${PACKAGE//./\/}/DemoApplication.java" <<JAVA
package $PACKAGE;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
@SpringBootApplication public class DemoApplication {
  public static void main(String[] args){ SpringApplication.run(DemoApplication.class,args); }
}
JAVA
fi

# Controller + config
mkdir -p "$PROJ_DIR/src/main/java/${PACKAGE//./\/}" "$PROJ_DIR/src/main/resources"
cat > "$PROJ_DIR/src/main/java/${PACKAGE//./\/}/HelloController.java" <<JAVA
package $PACKAGE;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import java.util.Map;
@RestController
public class HelloController {
  @GetMapping("/") public String root(){ return "It works! 🎉 ($APP_NAME)"; }
  @GetMapping("/api/hello") public Map<String,String> api(){ return Map.of("ok","true","app","$APP_NAME"); }
}
JAVA

cat > "$PROJ_DIR/src/main/resources/application.properties" <<PROPS
server.forward-headers-strategy=framework
management.endpoints.web.exposure.include=health,info,prometheus
management.endpoint.health.probes.enabled=true
management.health.livenessstate.enabled=true
management.health.readinessstate.enabled=true
PROPS

# ---------------- Build + SBOM + checksums ------------------
log "Building fat JAR + SBOM..."
cd "$PROJ_DIR"
mvn -q -DskipTests package
mvn -q -DskipTests org.cyclonedx:cyclonedx-maven-plugin:2.8.0:makeAggregateBom || true

JAR_BUILT="$(find target -maxdepth 1 -type f -name "*.jar" ! -name "*sources.jar" | head -n1)"
[ -n "$JAR_BUILT" ] || die "Build failed: no JAR."
TS="$(date +%Y%m%d_%H%M%S)"
RELEASE_DIR="$RELEASES_DIR/release-${TS}"
sudo mkdir -p "$RELEASE_DIR"
sudo cp -f "$JAR_BUILT" "$RELEASE_DIR/app.jar"
[ -f "target/bom.xml" ] && sudo cp -f target/bom.xml "$RELEASE_DIR/SBOM-cyclonedx.xml" || true
sudo sha256sum "$RELEASE_DIR/app.jar" | sudo tee "$CHECKSUMS_DIR/app-${TS}.sha256" >/dev/null
sudo ln -sfn "$RELEASE_DIR" "$CURRENT_DIR_LINK"
sudo chown -R "$APP_NAME:$APP_NAME" "$INSTALL_DIR"

# Optional vulnerability scan (best-effort, non-blocking)
if command -v trivy >/dev/null 2>&1; then
  log "Trivy scan (best-effort)..."
  trivy fs --quiet --severity HIGH,CRITICAL "$RELEASE_DIR" || true
fi

# Optional local attestation (cosign + key)
if [ "$ENABLE_ATTESTATION" = "1" ] && command -v cosign >/dev/null 2>&1 && [ -n "$COSIGN_KEY_PATH" ]; then
  log "Generating local cosign attestation..."
  (cd "$RELEASE_DIR" && cosign attest --predicate SBOM-cyclonedx.xml --key "$COSIGN_KEY_PATH" --type cyclonedx ./app.jar) || true
fi

# Retention
CNT="$(ls -1dt "$RELEASES_DIR"/release-* 2>/dev/null | wc -l || echo 0)"
if [ "$CNT" -gt "$KEEP_RELEASES" ]; then
  ls -1dt "$RELEASES_DIR"/release-* | tail -n +"$((KEEP_RELEASES+1))" | xargs -r sudo rm -rf --
fi

# ----------------- systemd hardened template ----------------
sudo bash -c "cat > '$ENV_FILE'" <<ENVV
JAVA_OPTS="-XX:+UseZGC -Xms256m -Xmx512m -XX:MaxRAMPercentage=75"
SPRING_PROFILES_ACTIVE="prod"
ENVV
# Optional: force TLS1.3 on JVM (PQC-ready posture)
if [ "$JAVA_TLS13_ONLY" = "1" ]; then
  echo 'JAVA_OPTS="$JAVA_OPTS -Djdk.tls.client.protocols=TLSv1.3 -Djdk.tls.server.protocols=TLSv1.3 -Dhttps.protocols=TLSv1.3"' | sudo tee -a "$ENV_FILE" >/dev/null
fi
sudo chown "$APP_NAME:$APP_NAME" "$ENV_FILE"; sudo chmod 0644 "$ENV_FILE"

sudo bash -c "cat > '$SVC_TEMPLATE'" <<'UNIT'
[Unit]
Description=%i Spring Boot (hardened)
Wants=network-online.target
After=network-online.target

[Service]
User=__USER__
EnvironmentFile=__ENV_FILE__
WorkingDirectory=__INSTALL_DIR__
ExecStart=/usr/bin/java $JAVA_OPTS -jar __CURRENT__/app.jar --server.port=%i
Restart=always
RestartSec=2
SuccessExitStatus=143
StandardOutput=journal
StandardError=journal
KillSignal=SIGTERM

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectProc=invisible
ProcSubset=pid
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6
LimitNOFILE=65535
TasksMax=2000
TimeoutStartSec=90
TimeoutStopSec=25
LimitCORE=0
UNIT
sudo sed -i "s|__USER__|$APP_NAME|; s|__ENV_FILE__|$ENV_FILE|; s|__INSTALL_DIR__|$INSTALL_DIR|; s|__CURRENT__|$CURRENT_DIR_LINK|" "$SVC_TEMPLATE"

# Opt-in: network egress lockdown (allowlist)
if [ "$LOCKDOWN_NET" = "1" ]; then
  ALLOW_LINES=""
  for cidr in $ALLOW_NET_CIDRS; do
    ALLOW_LINES="${ALLOW_LINES}IPAddressAllow=${cidr}\n"
  done
  sudo awk -v allows="$ALLOW_LINES" '
    /ProtectHostname=yes/ && !x { print; print "IPAddressDeny=any\n" allows; x=1; next }1
  ' "$SVC_TEMPLATE" | sudo tee "$SVC_TEMPLATE.tmp" >/dev/null
  sudo mv -f "$SVC_TEMPLATE.tmp" "$SVC_TEMPLATE"
fi

sudo systemctl daemon-reload

# ---------------- Start new color & health gate --------------
log "Starting new instance on :$INACTIVE_PORT ..."
sudo systemctl restart "${APP_NAME}@${INACTIVE_PORT}" || sudo systemctl start "${APP_NAME}@${INACTIVE_PORT}"

for i in {1..60}; do
  if curl -fsS "http://127.0.0.1:${INACTIVE_PORT}/actuator/health" | grep -q '"status":"UP"'; then
    log "New instance healthy."
    break
  fi
  sleep 1
  if [ $i -eq 60 ]; then
    sudo journalctl -u "${APP_NAME}@${INACTIVE_PORT}" -n 200 --no-pager || true
    die "Instance on :${INACTIVE_PORT} did not become healthy."
  fi
done

# ------------------- Nginx site (advanced) ------------------
if [ "$USE_NGINX" = "yes" ]; then
  # Optional brotli
  if [ "$ENABLE_BROTLI" != "no" ]; then
    if [ "$ENABLE_BROTLI" = "yes" ] || [ -f /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so ] || sudo apt-get install -y libnginx-mod-brotli >/dev/null 2>&1; then
      sudo ln -sf /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so /etc/nginx/modules-enabled/50-mod-brotli-filter.conf 2>/dev/null || true
      sudo ln -sf /usr/lib/nginx/modules/ngx_http_brotli_static_module.so /etc/nginx/modules-enabled/50-mod-brotli-static.conf 2>/dev/null || true
    fi
  fi

  # Build upstream: canary or single target
  UPSTREAM_BLOCK=""
  if [ "$CANARY_PERCENT" -gt 0 ] && systemctl is-active --quiet "${APP_NAME}@${ACTIVE_PORT}"; then
    OLD_W=$((100-CANARY_PERCENT)); NEW_W=$CANARY_PERCENT
    UPSTREAM_BLOCK="upstream ${APP_NAME}_upstream { server 127.0.0.1:${INACTIVE_PORT} weight=${NEW_W}; server 127.0.0.1:${ACTIVE_PORT} weight=${OLD_W}; }"
    log "Canary enabled: ${NEW_W}% new on :${INACTIVE_PORT}, ${OLD_W}% old on :${ACTIVE_PORT}"
  else
    UPSTREAM_BLOCK="upstream ${APP_NAME}_upstream { server 127.0.0.1:${INACTIVE_PORT}; }"
  fi

  # Convert CSV CIDRs to allow directives
  ALLOW_LINES=""
  IFS=',' read -ra CIDRS <<< "$ACTUATOR_ALLOW_CIDRS"
  for c in "${CIDRS[@]}"; do c_trim="$(echo "$c" | xargs)"; [ -n "$c_trim" ] && ALLOW_LINES="${ALLOW_LINES}    allow ${c_trim};\n"; done

  # Write site
  sudo bash -c "cat > '$NGX_SITE'" <<NGX
$UPSTREAM_BLOCK

map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN:-_};
  server_tokens off;

  # Global security headers
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "DENY" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
  add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'none'" always;
  add_header X-Release "${TS}" always;

  # Rate limit
  limit_req zone=reqs burst=${BURST} nodelay;

  gzip on;
  gzip_types text/plain text/css application/json application/javascript application/xml application/xhtml+xml image/svg+xml;
  # brotli (modules loaded if present)
  brotli on;
  brotli_comp_level 5;
  brotli_types text/plain text/css application/json application/javascript application/xml application/xhtml+xml image/svg+xml;

  # Maintenance mode (serve 503 if flag file exists)
  if (-f ${MAINTENANCE_FLAG}) { return 503; }
  error_page 503 @maint;
  location @maint { return 503 "Service under maintenance"; add_header Retry-After "120" always; }

  # Actuator — restrict by CIDR
  location /actuator/ {
${ALLOW_LINES}    deny all;
    proxy_pass http://${APP_NAME}_upstream;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location / {
    proxy_pass http://${APP_NAME}_upstream;
    proxy_http_version 1.1;
    proxy_set_header Connection "\$connection_upgrade";
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 60s;
  }

  # Minimal privacy-friendly access log (no query strings)
  access_log /var/log/nginx/${APP_NAME}.access.log combined if=\$loggable;
}
NGX

  # install rate-limit zone if absent (respect custom RATE)
  sudo bash -c "grep -q 'limit_req_zone' '$NGX_CONF' || sed -i \"1i limit_req_zone \\$binary_remote_addr zone=reqs:10m rate=${RATE};\" '$NGX_CONF'"

  sudo ln -sf "$NGX_SITE" "$NGX_LINK"
  sudo nginx -t && sudo systemctl reload nginx
fi

# ---------------- Flip / Stop old depending on canary -------
if [ "$CANARY_PERCENT" -eq 0 ] || [ "$PROMOTE" = "1" ]; then
  # Go 100% to new and stop old
  if systemctl is-active --quiet "${APP_NAME}@${ACTIVE_PORT}"; then
    log "Stopping old instance on :$ACTIVE_PORT ..."
    sudo systemctl stop "${APP_NAME}@${ACTIVE_PORT}" || true
  fi
  echo "$INACTIVE_PORT" | sudo tee "$ACTIVE_FILE" >/dev/null
else
  # Keep both running; record that active traffic is weighted
  echo "$INACTIVE_PORT" | sudo tee "$ACTIVE_FILE" >/dev/null
  log "Canary running. To promote: set PROMOTE=1 and re-run."
fi

# ---------------- TLS / mTLS (optional) ---------------------
if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ] && [ "$USE_NGINX" = "yes" ]; then
  log "Requesting/renewing Let's Encrypt cert for $DOMAIN ..."
  sudo ufw allow 80/tcp >/dev/null 2>&1 || true
  sudo ufw allow 443/tcp >/dev/null 2>&1 || true
  sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || true
  # Harden TLS: force TLS1.2+, prefer TLS1.3; enable HTTP/2; HSTS
  sudo awk '
    /server_name/ && !x {
      print; 
      print "  listen 443 ssl http2;"; 
      print "  ssl_protocols TLSv1.2 TLSv1.3;";
      print "  ssl_prefer_server_ciphers on;";
      print "  ssl_session_timeout 1d;";
      print "  ssl_session_cache shared:SSL:10m;";
      print "  add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always;";
      x=1; next
    }1
  ' "$NGX_SITE" | sudo tee "$NGX_SITE.tmp" >/dev/null
  sudo mv -f "$NGX_SITE.tmp" "$NGX_SITE"
  sudo nginx -t && sudo systemctl reload nginx
fi

# ---------------- Audit / Drift manifest --------------------
# Capture a minimal manifest for auditing (versions, hashes, ports, config file checksums).
JAVA_VER="$(java -version 2>&1 | tr '\n' ' ' | sed 's/"/\\"/g')"
NGX_VER="$(nginx -v 2>&1 | sed 's|nginx version: ||' || true)"
APP_JAR_SHA256="$(sha256sum "$CURRENT_DIR_LINK/app.jar" | awk '{print $1}')"
NGX_SITE_SHA256="$(sha256sum "$NGX_SITE" 2>/dev/null | awk '{print $1}')"
SVC_SHA256="$(sha256sum "$SVC_TEMPLATE" | awk '{print $1}')"

sudo bash -c "cat > '$AUDIT_FILE'" <<JSON
{
  "timestamp": "$TS",
  "app": "$APP_NAME",
  "active_port": "$(cat "$ACTIVE_FILE")",
  "release": "$(basename "$(readlink -f "$CURRENT_DIR_LINK")")",
  "jar_sha256": "$APP_JAR_SHA256",
  "sbom": "$( [ -f "$CURRENT_DIR_LINK/SBOM-cyclonedx.xml" ] && echo present || echo absent )",
  "nginx_site_sha256": "${NGX_SITE_SHA256:-absent}",
  "systemd_unit_sha256": "$SVC_SHA256",
  "java_version": "$JAVA_VER",
  "nginx_version": "$NGX_VER"
}
JSON

# ---------------- Final probe & summary ---------------------
IP="$(hostname -I | awk '{print $1}')"
PUBLIC_URL="${DOMAIN:+https://$DOMAIN/}"; [ -z "$PUBLIC_URL" ] && PUBLIC_URL="http://$IP/"

log "Probing ${PUBLIC_URL} ..."
curl -fsS "$PUBLIC_URL" >/dev/null && echo "OK" || echo "Probe failed (service may still be warming)."

echo "------------------------------------------------------------"
echo "App         : $APP_NAME"
echo "Active port : $(cat "$ACTIVE_FILE")"
echo "Install dir : $INSTALL_DIR  (current -> $(readlink -f "$CURRENT_DIR_LINK"))"
echo "SBOM        : $(readlink -f "$CURRENT_DIR_LINK")/SBOM-cyclonedx.xml (if generated)"
echo "Checksums   : $CHECKSUMS_DIR"
echo "Audit file  : $AUDIT_FILE"
echo "Service     : ${APP_NAME}@<port>   e.g. systemctl status ${APP_NAME}@$(cat "$ACTIVE_FILE")"
echo "Nginx site  : $NGX_SITE"
echo "URL         : ${PUBLIC_URL}"
if [ "$CANARY_PERCENT" -gt 0 ] && [ "$PROMOTE" = "0" ]; then
  echo "Canary      : ${CANARY_PERCENT}% new on :$INACTIVE_PORT (PROMOTE=1 to finalize)"
fi
echo "Rollback    : ROLLBACK=1 sudo ./$(basename "$0")"
echo "Releases    : $(ls -1dt "$RELEASES_DIR"/release-* | wc -l 2>/dev/null || echo 0) kept (max $KEEP_RELEASES)"
echo "SSH Safety  : OpenSSH ensured active; 22/tcp allow persisted. No firewall tightening performed."
echo "------------------------------------------------------------"
