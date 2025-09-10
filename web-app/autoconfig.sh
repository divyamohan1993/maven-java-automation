#!/usr/bin/env bash
# autoconfig-boot.sh — One-click Spring Boot (fat JAR) + optional Nginx reverse proxy
set -euo pipefail

GROUP_ID="com.example"
ARTIFACT_ID="hello-boot"
PACKAGE="com.example.demo"
BOOT_VERSION="3.3.4"           # Safe to omit if needed
JAVA_RELEASE="17"
WORKDIR="${PWD}"
PROJECT_DIR="${WORKDIR}/${ARTIFACT_ID}"
SERVICE_NAME="${ARTIFACT_ID}.service"
INSTALL_DIR="/opt/${ARTIFACT_ID}"
JAR_PATH="${INSTALL_DIR}/app.jar"
USE_NGINX="yes"                # set "no" to skip Nginx proxy

echo ">>> Installing base deps..."
sudo apt-get update -y
sudo apt-get install -y openjdk-17-jdk maven ca-certificates curl unzip

# Choose port (avoid clash with Tomcat or anything on :8080)
BOOT_PORT=8080
if systemctl is-active --quiet tomcat10 2>/dev/null || ss -ltn 2>/dev/null | grep -q ":8080 "; then
  BOOT_PORT=8081
fi

# Always regenerate the project
rm -rf "${PROJECT_DIR}" "${INSTALL_DIR}"
mkdir -p "${PROJECT_DIR}"
cd "${WORKDIR}"

echo ">>> Generating Spring Boot project (web)..."
ZIP_OK=0
# Try with explicit bootVersion first; if 400/err, retry without it
if curl -fsSL -G "https://start.spring.io/starter.zip" \
  --data-urlencode "type=maven-project" \
  --data-urlencode "language=java" \
  --data-urlencode "bootVersion=${BOOT_VERSION}" \
  --data-urlencode "baseDir=${ARTIFACT_ID}" \
  --data-urlencode "groupId=${GROUP_ID}" \
  --data-urlencode "artifactId=${ARTIFACT_ID}" \
  --data-urlencode "name=${ARTIFACT_ID}" \
  --data-urlencode "packageName=${PACKAGE}" \
  --data-urlencode "dependencies=web" -o boot.zip; then
  ZIP_OK=1
else
  echo ">>> start.spring.io rejected bootVersion; retrying without bootVersion..."
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
fi

if [ "${ZIP_OK}" -eq 1 ]; then
  unzip -qo boot.zip -d "${WORKDIR}"
  rm -f boot.zip
else
  echo ">>> start.spring.io unreachable — using local scaffold"
  mkdir -p "${PROJECT_DIR}/src/main/java/${PACKAGE//./\/}" \
           "${PROJECT_DIR}/src/test/java/${PACKAGE//./\/}" \
           "${PROJECT_DIR}/src/main/resources"
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
import org.springframework.web.bind.annotation.*;
@SpringBootApplication
@RestController
public class DemoApplication {
  @GetMapping("/")
  public String home() { return "It works! 🎉 (Spring Boot)"; }
  public static void main(String[] args) { SpringApplication.run(DemoApplication.class, args); }
}
JAVA
fi

cd "${PROJECT_DIR}"

echo ">>> Building fat JAR with Maven..."
mvn -q -DskipTests package

echo ">>> Installing app to ${INSTALL_DIR}..."
sudo mkdir -p "${INSTALL_DIR}"
JAR_BUILT="$(find target -maxdepth 1 -type f -name "*.jar" ! -name "*sources.jar" | head -n1)"
if [ -z "${JAR_BUILT}" ]; then
  echo "ERROR: No JAR produced under target/. Check Maven output."
  exit 1
fi
sudo cp -f "${JAR_BUILT}" "${JAR_PATH}"

# systemd service
sudo bash -c "cat > /etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=${ARTIFACT_ID} Spring Boot
Wants=network-online.target
After=network-online.target

[Service]
User=root
ExecStart=/usr/bin/java -jar ${JAR_PATH} --server.port=${BOOT_PORT}
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

APP_URL="http://localhost:${BOOT_PORT}/"

if [ "${USE_NGINX}" = "yes" ]; then
  echo ">>> Installing & configuring Nginx reverse proxy..."
  sudo apt-get install -y nginx
  # remove the default site to avoid "duplicate default server"
  sudo rm -f /etc/nginx/sites-enabled/default

  sudo bash -c "cat > /etc/nginx/sites-available/${ARTIFACT_ID}" <<NGX
server {
  listen 80;
  listen [::]:80;
  server_name _;
  location / {
    proxy_pass http://127.0.0.1:${BOOT_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGX
  sudo ln -sf "/etc/nginx/sites-available/${ARTIFACT_ID}" "/etc/nginx/sites-enabled/${ARTIFACT_ID}"
  sudo nginx -t
  sudo systemctl restart nginx
  APP_URL="http://localhost/"
fi

# quick probe
if command -v curl >/dev/null; then
  echo ">>> Probing ${APP_URL} ..."
  curl -fsS "${APP_URL}" >/dev/null && echo "OK" || echo "Probe failed (firewall or service starting up?)"
fi

echo "------------------------------------------------------------"
echo "Boot URL   : ${APP_URL}"
echo "Project    : ${PROJECT_DIR}"
echo "Service    : ${SERVICE_NAME}"
echo "Jar        : ${JAR_PATH}"
echo "Port       : ${BOOT_PORT}"
echo "------------------------------------------------------------"
