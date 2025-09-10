#!/usr/bin/env bash
# autoconfig-boot.sh — One-click Spring Boot fat JAR + Nginx (idempotent)
set -euo pipefail

GROUP_ID="com.example"
ARTIFACT_ID="hello-boot"
PACKAGE="com.example.demo"
JAVA_RELEASE="17"
WORKDIR="${PWD}"
PROJECT_DIR="${WORKDIR}/${ARTIFACT_ID}"
SERVICE_NAME="${ARTIFACT_ID}.service"
INSTALL_DIR="/opt/${ARTIFACT_ID}"
JAR_PATH="${INSTALL_DIR}/app.jar"
USE_NGINX="yes"

echo ">>> Installing base deps..."
sudo apt-get update -y
sudo apt-get install -y openjdk-17-jdk maven ca-certificates curl unzip

# Choose a free port (avoid Tomcat on 8080)
BOOT_PORT=8080
if systemctl is-active --quiet tomcat10 2>/dev/null || ss -ltn 2>/dev/null | grep -q ":8080 "; then
  BOOT_PORT=8081
fi

# Clean slate
rm -rf "${PROJECT_DIR}" "${INSTALL_DIR}"
mkdir -p "${PROJECT_DIR}"
cd "${WORKDIR}"

echo ">>> Generating Spring Boot project (web)..."
ZIP_OK=0
# Try start.spring.io without strict bootVersion to avoid 400s
if curl -fsSL -G "https://start.spring.io/starter.zip" \
  --data-urlencode "type=maven-project" \
  --data-urlencode "language=java" \
  --data-urlencode "baseDir=${ARTIFACT_ID}" \
  --data-urlencode "groupId=${GROUP_ID}" \
  --data-urlencode "artifactId=${ARTIFACT_ID}" \
  --data-urlencode "name=${ARTIFACT_ID}" \
  --data-urlencode "packageName=${PACKAGE}" \
  --data-urlencode "dependencies=web" -o boot.zip; then
  ZIP_OK=1
fi

if [ "${ZIP_OK}" -eq 1 ]; then
  unzip -qo boot.zip -d "${WORKDIR}"
  rm -f boot.zip
else
  echo ">>> start.spring.io unreachable — using local scaffold"
  mkdir -p "${PROJECT_DIR}/src/main/java/${PACKAGE//./\/}" \
           "${PROJECT_DIR}/src/test/java/${PACKAGE//./\/}" \
           "${PROJECT_DIR}/src/main/resources"

  # Minimal Boot pom
  cat > "${PROJECT_DIR}/pom.xml" <<'POM'
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
  <artifactId>__ARTIFACT_ID__</artifactId>
  <version>1.0.0</version>
  <name>__ARTIFACT_ID__</name>
  <description>Spring Boot app</description>
  <properties>
    <java.version>__JAVA_RELEASE__</java.version>
  </properties>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
POM
  sed -i "s|__GROUP_ID__|$GROUP_ID|g; s|__ARTIFACT_ID__|$ARTIFACT_ID|g; s|__JAVA_RELEASE__|$JAVA_RELEASE|g" "${PROJECT_DIR}/pom.xml"

  cat > "${PROJECT_DIR}/src/main/java/${PACKAGE//./\/}/DemoApplication.java" <<JAVA
package ${PACKAGE};
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
@SpringBootApplication
public class DemoApplication {
  public static void main(String[] args) { SpringApplication.run(DemoApplication.class, args); }
}
JAVA
fi

# Ensure we ALWAYS have a root controller + health endpoint
mkdir -p "${PROJECT_DIR}/src/main/java/${PACKAGE//./\/}" "${PROJECT_DIR}/src/main/resources"
cat > "${PROJECT_DIR}/src/main/java/${PACKAGE//./\/}/HelloController.java" <<JAVA
package ${PACKAGE};
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {
  @GetMapping("/")
  public String root() { return "It works! 🎉 (Spring Boot)"; }

  @GetMapping("/healthz")
  public String health() { return "ok"; }
}
JAVA

# Pin port and basic proxy headers
cat > "${PROJECT_DIR}/src/main/resources/application.properties" <<PROPS
server.port=${BOOT_PORT}
server.forward-headers-strategy=framework
management.endpoints.web.exposure.include=health,info
PROPS

cd "${PROJECT_DIR}"

echo ">>> Building fat JAR with Maven..."
mvn -q -DskipTests package

echo ">>> Installing app to ${INSTALL_DIR}..."
sudo mkdir -p "${INSTALL_DIR}"
JAR_BUILT="$(find target -maxdepth 1 -type f -name "*.jar" ! -name "*sources.jar" | head -n1)"
[ -n "${JAR_BUILT}" ] || { echo "ERROR: No JAR produced under target/"; exit 1; }
sudo cp -f "${JAR_BUILT}" "${JAR_PATH}"

# systemd service (binds to BOOT_PORT, logs to journal)
sudo bash -c "cat > /etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=${ARTIFACT_ID} Spring Boot
Wants=network-online.target
After=network-online.target

[Service]
User=root
ExecStart=/usr/bin/java -jar ${JAR_PATH}
Restart=always
RestartSec=2
Environment=JAVA_TOOL_OPTIONS=-XX:+UseZGC
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

echo ">>> Enabling & starting service..."
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"

# Wait until the app is ready
echo ">>> Waiting for app on :${BOOT_PORT} ..."
for i in {1..30}; do
  if curl -fsS "http://127.0.0.1:${BOOT_PORT}/healthz" >/dev/null 2>&1; then
    echo "App is up."
    break
  fi
  sleep 1
  if [ $i -eq 30 ]; then
    echo "App did not become ready in time. Recent logs:"
    sudo journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
    exit 1
  fi
done

APP_URL="http://localhost:${BOOT_PORT}/"

if [ "${USE_NGINX}" = "yes" ]; then
  echo ">>> Installing & configuring Nginx reverse proxy..."
  sudo apt-get install -y nginx
  sudo rm -f /etc/nginx/sites-enabled/default

  sudo bash -c "cat > /etc/nginx/sites-available/${ARTIFACT_ID}" <<NGX
server {
  listen 80;
  listen [::]:80;
  server_name _;
  location / {
    proxy_pass http://127.0.0.1:${BOOT_PORT};
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
  sudo ln -sf "/etc/nginx/sites-available/${ARTIFACT_ID}" "/etc/nginx/sites-enabled/${ARTIFACT_ID}"
  sudo nginx -t
  sudo systemctl restart nginx
  APP_URL="http://localhost/"
fi

# Final probe
echo ">>> Probing ${APP_URL} ..."
curl -fsS "${APP_URL}" >/dev/null && echo "OK" || echo "Probe failed (but app is up on :${BOOT_PORT})"

echo "------------------------------------------------------------"
echo "Boot URL   : ${APP_URL}"
echo "Direct URL : http://$(hostname -I | awk '{print $1}'):${BOOT_PORT}/"
echo "Project    : ${PROJECT_DIR}"
echo "Service    : ${SERVICE_NAME}"
echo "Jar        : ${JAR_PATH}"
echo "Port       : ${BOOT_PORT}"
echo "------------------------------------------------------------"

