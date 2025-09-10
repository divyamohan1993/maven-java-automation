#!/usr/bin/env bash
# oneclick-deploy-enterprise.sh — Spring Boot fat JAR + blue/green + hardened systemd + Nginx + TLS + SBOM
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
KEEP_RELEASES="${KEEP_RELEASES:-5}"       # how many to keep
JDK_PKG="${JDK_PKG:-openjdk-17-jdk}"
RATE="${RATE:-10r/s}"                     # req/s per IP
BURST="${BURST:-20}"                      # burst size
ROLLBACK="${ROLLBACK:-0}"                 # 1 = roll back to previous release
# --------------------------------------------

WORKDIR="$PWD"
PROJ_DIR="$WORKDIR/$APP_NAME"
INSTALL_DIR="/opt/$APP_NAME"
RELEASES_DIR="$INSTALL_DIR/releases"
CURRENT_DIR_LINK="$INSTALL_DIR/current"     # symlink to DIR release-TS
CHECKSUMS_DIR="$INSTALL_DIR/checksums"
ENV_FILE="/etc/$APP_NAME/env"
ACTIVE_FILE="$INSTALL_DIR/active_port"
SVC_TEMPLATE="/etc/systemd/system/${APP_NAME}@.service"
NGX_SITE="/etc/nginx/sites-available/$APP_NAME"
NGX_LINK="/etc/nginx/sites-enabled/$APP_NAME"

log(){ echo ">>> $*"; }
die(){ echo "!!! $*" >&2; exit 1; }
trap 'echo "!!! failed at line $LINENO"; exit 1' ERR

# --------------- ROLLBACK path ---------------
if [ "$ROLLBACK" = "1" ]; then
  [ -d "$RELEASES_DIR" ] || die "No releases found to roll back."
  CUR="$(readlink -f "$CURRENT_DIR_LINK" || true)"
  PREV="$(ls -1dt "$RELEASES_DIR"/release-* 2>/dev/null | grep -vx "$CUR" | head -n1 || true)"
  [ -n "$PREV" ] || die "No previous release."
  sudo ln -sfn "$PREV" "$CURRENT_DIR_LINK"
  # restart inactive color on current bits, then flip
  ACTIVE_PORT="$( [ -f "$ACTIVE_FILE" ] && cat "$ACTIVE_FILE" || echo "$PORT_A" )"
  INACTIVE_PORT="$PORT_B"; [ "$ACTIVE_PORT" = "$PORT_B" ] && INACTIVE_PORT="$PORT_A"
  log "Rolling back to $(basename "$PREV"); restarting ${APP_NAME}@${INACTIVE_PORT}..."
  sudo systemctl daemon-reload
  sudo systemctl restart "${APP_NAME}@${INACTIVE_PORT}"
  # quick health gate
  for i in {1..60}; do
    curl -fsS "http://127.0.0.1:${INACTIVE_PORT}/actuator/health" | grep -q '"status":"UP"' && break
    sleep 1
    [ $i -eq 60 ] && die "Rollback instance on :${INACTIVE_PORT} not healthy."
  done
  # point Nginx upstream to new port if site exists
  if [ -f "$NGX_SITE" ]; then
    sudo sed -i "s|server 127.0.0.1:[0-9]\+;|server 127.0.0.1:${INACTIVE_PORT};|" "$NGX_SITE"
    sudo nginx -t && sudo systemctl reload nginx || true
  fi
  echo "$INACTIVE_PORT" | sudo tee "$ACTIVE_FILE" >/dev/null
  log "Rollback complete. Active port now $(cat "$ACTIVE_FILE")."
  exit 0
fi

# --------------- Install deps ---------------
log "Installing base deps..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "$JDK_PKG" maven ca-certificates curl unzip coreutils \
  nginx certbot python3-certbot-nginx || true
command -v ss >/dev/null 2>&1 || sudo apt-get install -y iproute2 >/dev/null 2>&1 || true
command -v sha256sum >/dev/null 2>&1 || sudo apt-get install -y coreutils >/dev/null 2>&1 || true

# --- NEVER BREAK SSH (GCE-safe) ---
# 1) Ensure OpenSSH is present and running (don’t restart if already up)
sudo apt-get install -y openssh-server
sudo systemctl enable ssh >/dev/null 2>&1 || true
sudo systemctl start  ssh >/dev/null 2>&1 || true

# 2) If UFW exists, guarantee 22/tcp stays open without changing overall policy
if command -v ufw >/dev/null 2>&1; then
  # Allow port 22 generally…
  sudo ufw allow 22/tcp >/dev/null 2>&1 || true
  # …and explicitly allow your current client IP if we can detect it
  REMOTE_IP="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $1}')"
  if [ -n "$REMOTE_IP" ]; then
    sudo ufw allow from "$REMOTE_IP" to any port 22 proto tcp >/dev/null 2>&1 || true
  fi
  # DO NOT enable or reload UFW here; we never call `ufw enable`.
fi

# 3) If nftables is in use and default-drop rules exist, add a permissive 22/tcp rule (no reload)
if command -v nft >/dev/null 2>&1; then
  # Add only if the allow isn’t already present
  if ! sudo nft list ruleset 2>/dev/null | grep -q 'tcp dport 22 accept'; then
    sudo nft add rule inet filter input tcp dport 22 ct state new,established accept >/dev/null 2>&1 || true
  fi
fi

# 4) Sanity check: confirm something is listening on :22
if ! ss -ltn 2>/dev/null | grep -q ':22 '; then
  echo "!!! Warning: nothing is listening on port 22; attempting to (re)start sshd"
  sudo systemctl start ssh || true
fi



# --------------- Users & dirs ---------------
if ! id "$APP_NAME" >/dev/null 2>&1; then
  sudo useradd -r -m -U -d "$INSTALL_DIR" -s /usr/sbin/nologin "$APP_NAME"
fi
sudo mkdir -p "$RELEASES_DIR" "$CHECKSUMS_DIR"

# Remove default nginx site to avoid conflicts
if [ "$USE_NGINX" = "yes" ]; then
  sudo rm -f /etc/nginx/sites-enabled/default || true
fi

# ---- Blue/green port selection ----
ACTIVE_PORT="$( [ -f "$ACTIVE_FILE" ] && cat "$ACTIVE_FILE" || echo "$PORT_A" )"
INACTIVE_PORT="$PORT_B"; [ "$ACTIVE_PORT" = "$PORT_B" ] && INACTIVE_PORT="$PORT_A"

# --------------- Generate project ---------------
rm -rf "$PROJ_DIR"; mkdir -p "$PROJ_DIR"; cd "$WORKDIR"
log "Generating Spring Boot project (web + actuator)..."
ZIP_OK=0
if curl -fsSL -G "https://start.spring.io/starter.zip" \
  --data-urlencode "type=maven-project" \
  --data-urlencode "language=java" \
  --data-urlencode "baseDir=$APP_NAME" \
  --data-urlencode "groupId=$GROUP_ID" \
  --data-urlencode "artifactId=$APP_NAME" \
  --data-urlencode "name=$APP_NAME" \
  --data-urlencode "packageName=$PACKAGE" \
  --data-urlencode "dependencies=web,actuator" -o boot.zip; then
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
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-actuator</artifactId></dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin><groupId>org.springframework.boot</groupId><artifactId>spring-boot-maven-plugin</artifactId></plugin>
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
# Explicit Actuator on same port + sane headers behavior
cat > "$PROJ_DIR/src/main/resources/application.properties" <<PROPS
server.forward-headers-strategy=framework
management.endpoints.web.exposure.include=health,info
PROPS

# --------------- Build + SBOM + checksums ---------------
log "Building fat JAR + SBOM..."
cd "$PROJ_DIR"
mvn -q -DskipTests package
# SBOM (CycloneDX) without touching POM
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

# Retention
CNT="$(ls -1dt "$RELEASES_DIR"/release-* 2>/dev/null | wc -l || echo 0)"
if [ "$CNT" -gt "$KEEP_RELEASES" ]; then
  ls -1dt "$RELEASES_DIR"/release-* | tail -n +"$((KEEP_RELEASES+1))" | xargs -r sudo rm -rf --
fi

# --------------- systemd hardened template ---------------
sudo mkdir -p "$(dirname "$ENV_FILE")"
sudo bash -c "cat > '$ENV_FILE'" <<ENVV
JAVA_OPTS="-XX:+UseZGC -Xms256m -Xmx512m -XX:MaxRAMPercentage=75"
SPRING_PROFILES_ACTIVE="prod"
ENVV
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
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT
sudo sed -i "s|__USER__|$APP_NAME|; s|__ENV_FILE__|$ENV_FILE|; s|__INSTALL_DIR__|$INSTALL_DIR|; s|__CURRENT__|$CURRENT_DIR_LINK|" "$SVC_TEMPLATE"
sudo systemctl daemon-reload

# --------------- Start new color & health gate ---------------
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

# --------------- Nginx secure site ---------------
if [ "$USE_NGINX" = "yes" ]; then
  # rate-limit zone
  sudo bash -c 'grep -q "limit_req_zone" /etc/nginx/nginx.conf || sed -i "1i limit_req_zone \$binary_remote_addr zone=reqs:10m rate=10r/s;" /etc/nginx/nginx.conf'
  sudo bash -c "cat > '$NGX_SITE'" <<NGX
upstream ${APP_NAME}_upstream { server 127.0.0.1:${INACTIVE_PORT}; }

server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN:-_};
  # Security headers
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "DENY" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
  add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'none'" always;
  # Rate limit
  limit_req zone=reqs burst=${BURST} nodelay;

  gzip on;
  gzip_types text/plain text/css application/json application/javascript application/xml application/xhtml+xml image/svg+xml;

  location / {
    proxy_pass http://${APP_NAME}_upstream;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 60s;
  }
}
NGX
  sudo ln -sf "$NGX_SITE" "$NGX_LINK"
  sudo nginx -t && sudo systemctl reload nginx
fi

# --------------- Flip active, stop old ---------------
if systemctl is-active --quiet "${APP_NAME}@${ACTIVE_PORT}"; then
  log "Stopping old instance on :$ACTIVE_PORT ..."
  sudo systemctl stop "${APP_NAME}@${ACTIVE_PORT}" || true
fi
echo "$INACTIVE_PORT" | sudo tee "$ACTIVE_FILE" >/dev/null

# --------------- TLS (optional) ---------------
if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ] && [ "$USE_NGINX" = "yes" ]; then
  log "Requesting/renewing Let's Encrypt cert for $DOMAIN ..."
  sudo ufw allow 80/tcp >/dev/null 2>&1 || true
  sudo ufw allow 443/tcp >/dev/null 2>&1 || true
  sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || true
  # Harden TLS
  sudo bash -c "cat >> '$NGX_SITE'" <<'TLS'
# Enforce HTTPS with HSTS (preload-ready)
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
TLS
  sudo nginx -t && sudo systemctl reload nginx
fi

# --------------- Final probe & summary ---------------
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
echo "Service     : ${APP_NAME}@<port>   e.g. systemctl status ${APP_NAME}@$(cat "$ACTIVE_FILE")"
echo "Nginx site  : $NGX_SITE"
echo "URL         : ${PUBLIC_URL}"
echo "Rollback    : ROLLBACK=1 bash $(basename "$0")"
echo "Releases    : $(ls -1dt "$RELEASES_DIR"/release-* | wc -l 2>/dev/null || echo 0) kept (max $KEEP_RELEASES)"
echo "------------------------------------------------------------"
