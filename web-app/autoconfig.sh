#!/usr/bin/env bash
# oneclick-deploy.sh — Spring Boot fat JAR + blue/green + Nginx + optional TLS
set -euo pipefail

# ---------- Config (override with env) ----------
APP_NAME="${APP_NAME:-hello-boot}"
GROUP_ID="${GROUP_ID:-com.example}"
PACKAGE="${PACKAGE:-com.example.demo}"
JAVA_RELEASE="${JAVA_RELEASE:-17}"
USE_NGINX="${USE_NGINX:-yes}"          # yes|no
DOMAIN="${DOMAIN:-}"                   # example.com (enables TLS if EMAIL set)
EMAIL="${EMAIL:-}"                     # Let's Encrypt email
PORT_A="${PORT_A:-8081}"               # blue
PORT_B="${PORT_B:-8082}"               # green
JDK_PKG="${JDK_PKG:-openjdk-17-jdk}"
# ------------------------------------------------

WORKDIR="$PWD"
PROJ_DIR="$WORKDIR/$APP_NAME"
INSTALL_DIR="/opt/$APP_NAME"
RELEASES_DIR="$INSTALL_DIR/releases"
CURRENT_DIR_LINK="$INSTALL_DIR/current"          # <-- symlink to a DIR
ENV_FILE="/etc/$APP_NAME/env"
ACTIVE_FILE="$INSTALL_DIR/active_port"
SVC_TEMPLATE="/etc/systemd/system/${APP_NAME}@.service"
NGX_SITE="/etc/nginx/sites-available/$APP_NAME"
NGX_LINK="/etc/nginx/sites-enabled/$APP_NAME"

log() { echo ">>> $*"; }

log "Installing base deps..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "$JDK_PKG" maven ca-certificates curl unzip \
  nginx certbot python3-certbot-nginx || true

# determine blue/green ports
ACTIVE_PORT="$( [ -f "$ACTIVE_FILE" ] && cat "$ACTIVE_FILE" || echo "$PORT_A" )"
INACTIVE_PORT="$PORT_B"; [ "$ACTIVE_PORT" = "$PORT_B" ] && INACTIVE_PORT="$PORT_A"

# service user
if ! id "$APP_NAME" >/dev/null 2>&1; then
  sudo useradd -r -m -U -d "$INSTALL_DIR" -s /usr/sbin/nologin "$APP_NAME"
fi

# nginx baseline
if [ "$USE_NGINX" = "yes" ]; then
  sudo rm -f /etc/nginx/sites-enabled/default || true
fi

# fresh project
rm -rf "$PROJ_DIR"
mkdir -p "$PROJ_DIR"
cd "$WORKDIR"

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
  log "start.spring.io unreachable — local scaffold fallback"
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

# minimal controller + resources
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

# build
log "Building fat JAR..."
cd "$PROJ_DIR"
mvn -q -DskipTests package
JAR_BUILT="$(find target -maxdepth 1 -type f -name "*.jar" ! -name "*sources.jar" | head -n1)"
[ -n "$JAR_BUILT" ] || { echo "Build failed: no JAR"; exit 1; }

# ---- RELEASE LAYOUT FIX ----
TS="$(date +%Y%m%d_%H%M%S)"
RELEASE_DIR="$RELEASES_DIR/release-${TS}"
sudo mkdir -p "$RELEASE_DIR"
sudo cp -f "$JAR_BUILT" "$RELEASE_DIR/app.jar"
sudo ln -sfn "$RELEASE_DIR" "$CURRENT_DIR_LINK"   # <-- symlink to DIR now
sudo chown -R "$APP_NAME":"$APP_NAME" "$INSTALL_DIR"
# ---------------------------------

# env & unit
sudo mkdir -p "$(dirname "$ENV_FILE")"
sudo bash -c "cat > '$ENV_FILE'" <<ENVV
JAVA_OPTS="-XX:+UseZGC -Xms256m -Xmx512m"
SPRING_PROFILES_ACTIVE="prod"
ENVV
sudo chown "$APP_NAME":"$APP_NAME" "$ENV_FILE"; sudo chmod 0644 "$ENV_FILE"

sudo bash -c "cat > '$SVC_TEMPLATE'" <<'UNIT'
[Unit]
Description=%i Spring Boot service (templated)
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

[Install]
WantedBy=multi-user.target
UNIT
sudo sed -i "s|__USER__|$APP_NAME|; s|__ENV_FILE__|$ENV_FILE|; s|__INSTALL_DIR__|$INSTALL_DIR|; s|__CURRENT__|$CURRENT_DIR_LINK|" "$SVC_TEMPLATE"
sudo systemctl daemon-reload

# start/restart new color
log "Starting new instance on :$INACTIVE_PORT ..."
if systemctl list-unit-files | grep -q "^${APP_NAME}@.service"; then
  sudo systemctl restart "${APP_NAME}@${INACTIVE_PORT}" || sudo systemctl start "${APP_NAME}@${INACTIVE_PORT}"
else
  sudo systemctl start "${APP_NAME}@${INACTIVE_PORT}"
fi

# wait for health
for i in {1..60}; do
  if curl -fsS "http://127.0.0.1:${INACTIVE_PORT}/actuator/health" | grep -q '"status":"UP"'; then
    log "New instance healthy."; break
  fi
  sleep 1
  if [ $i -eq 60 ]; then
    echo "ERROR: instance on ${INACTIVE_PORT} not healthy. Recent logs:"
    sudo journalctl -u "${APP_NAME}@${INACTIVE_PORT}" -n 120 --no-pager || true
    exit 1
  fi
done

# nginx config (HTTP; TLS optional)
if [ "$USE_NGINX" = "yes" ]; then
  sudo bash -c "cat > '$NGX_SITE'" <<NGX
upstream ${APP_NAME}_upstream { server 127.0.0.1:${INACTIVE_PORT}; }
server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN:-_};
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

# flip active
if systemctl is-active --quiet "${APP_NAME}@${ACTIVE_PORT}"; then
  log "Stopping old instance on :$ACTIVE_PORT ..."
  sudo systemctl stop "${APP_NAME}@${ACTIVE_PORT}" || true
fi
echo "$INACTIVE_PORT" | sudo tee "$ACTIVE_FILE" >/dev/null

# HTTPS (optional)
if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ] && [ "$USE_NGINX" = "yes" ]; then
  log "Enabling HTTPS via Let's Encrypt for $DOMAIN ..."
  sudo ufw allow 80/tcp >/dev/null 2>&1 || true
  sudo ufw allow 443/tcp >/dev/null 2>&1 || true
  sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || true
  sudo systemctl reload nginx || true
fi

# probe
PUBLIC_URL="http://${DOMAIN:-localhost}/"
[ -z "$DOMAIN" ] && PUBLIC_URL="http://$(hostname -I | awk '{print $1}')/"
log "Probing ${PUBLIC_URL} ..."
curl -fsS "$PUBLIC_URL" >/dev/null && echo "OK" || echo "Probe failed (if HTTPS, try https://$DOMAIN/)"

echo "------------------------------------------------------------"
echo "App         : $APP_NAME"
echo "Active port : $(cat "$ACTIVE_FILE")"
echo "Project     : $PROJ_DIR"
echo "Install dir : $INSTALL_DIR  (current -> $(readlink -f "$CURRENT_DIR_LINK"))"
echo "Service     : ${APP_NAME}@<port>  e.g. ${APP_NAME}@${INACTIVE_PORT}"
echo "Nginx site  : $NGX_SITE"
[ -n "$DOMAIN" ] && echo "URL         : https://$DOMAIN/" || echo "URL         : $PUBLIC_URL"
echo "Tip         : Re-run to roll a new release (blue/green)."
echo "------------------------------------------------------------"
