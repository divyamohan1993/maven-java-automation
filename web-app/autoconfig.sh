#!/usr/bin/env bash
# autoconfig.sh — one-click Maven webapp to Tomcat (Ubuntu/Debian)
set -euo pipefail

GROUP_ID="com.example"
ARTIFACT_ID="hello-web"
VERSION="1.0.0"
JAVA_RELEASE="17"
ARCHETYPE_VERSION="1.4"
PROJECT_DIR="$PWD/$ARTIFACT_ID"

echo ">>> Starting one-click Maven webapp setup..."

# --- base deps ---
if ! command -v apt-get >/dev/null; then echo "Needs Debian/Ubuntu (apt-get)"; exit 1; fi
sudo apt-get update -y
sudo apt-get install -y openjdk-17-jdk maven ca-certificates curl wget

# --- Tomcat install (pkg -> manual fallback) ---
TOMCAT_SVC=""
TOMCAT_HOME=""

if apt-cache policy tomcat10 | grep -q Candidate; then
  echo ">>> Installing Tomcat 10 from package repo..."
  sudo apt-get install -y tomcat10
  TOMCAT_SVC="tomcat10"
  TOMCAT_HOME="/var/lib/tomcat10"
else
  echo ">>> tomcat10 package not found. Installing Tomcat 10.1 manually..."
  TOMCAT_VERSION="10.1.24"
  TOMCAT_HOME="/opt/tomcat"
  TOMCAT_SVC="tomcat10"

  # non-login service user
  if ! id tomcat &>/dev/null; then
    sudo useradd -r -m -U -d /opt/tomcat -s /usr/sbin/nologin tomcat
  fi

  sudo mkdir -p "$TOMCAT_HOME"
  cd /tmp
  if [ ! -f "apache-tomcat-${TOMCAT_VERSION}.tar.gz" ]; then
    wget -q "https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
  fi
  sudo tar -xzf "apache-tomcat-${TOMCAT_VERSION}.tar.gz" -C "$TOMCAT_HOME" --strip-components=1
  sudo chown -R tomcat:tomcat "$TOMCAT_HOME"
  sudo chmod +x "$TOMCAT_HOME/bin/"*.sh

  # systemd unit
  sudo tee /etc/systemd/system/tomcat10.service >/dev/null <<EOF
[Unit]
Description=Apache Tomcat 10
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment=JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
Environment=CATALINA_HOME=${TOMCAT_HOME}
Environment=CATALINA_BASE=${TOMCAT_HOME}
Environment=CATALINA_PID=${TOMCAT_HOME}/temp/tomcat.pid
Environment=CATALINA_OPTS=-Xms256M -Xmx512M
ExecStart=${TOMCAT_HOME}/bin/startup.sh
ExecStop=${TOMCAT_HOME}/bin/shutdown.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable tomcat10
fi

# --- generate webapp ---
if [ ! -d "$PROJECT_DIR" ]; then
  echo ">>> Generating Maven webapp project: $ARTIFACT_ID"
  mvn archetype:generate \
    -DgroupId="$GROUP_ID" \
    -DartifactId="$ARTIFACT_ID" \
    -DarchetypeArtifactId=maven-archetype-webapp \
    -DarchetypeVersion="$ARCHETYPE_VERSION" \
    -DinteractiveMode=false
else
  echo ">>> Project exists at $PROJECT_DIR (skip generate)"
fi

cd "$PROJECT_DIR"

# --- POM (Jakarta for Tomcat 10) ---
cat > pom.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${GROUP_ID}</groupId>
  <artifactId>${ARTIFACT_ID}</artifactId>
  <version>${VERSION}</version>
  <packaging>war</packaging>

  <properties>
    <maven.compiler.release>${JAVA_RELEASE}</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>

  <dependencies>
    <!-- Tomcat 10+ uses jakarta.* -->
    <dependency>
      <groupId>jakarta.servlet</groupId>
      <artifactId>jakarta.servlet-api</artifactId>
      <version>5.0.0</version>
      <scope>provided</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.11.0</version>
        <configuration><release>\${maven.compiler.release}</release></configuration>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-war-plugin</artifactId>
        <version>3.4.0</version>
      </plugin>
    </plugins>
  </build>
</project>
EOF

# minimal index.jsp
mkdir -p src/main/webapp
if [ ! -f src/main/webapp/index.jsp ]; then
  cat > src/main/webapp/index.jsp <<'JSP'
<%@ page contentType="text/html; charset=UTF-8" %>
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Hello Web</title></head>
<body><h1>It works! 🎉</h1><p>Deployed via autoconfig.sh</p></body></html>
JSP
fi

# --- build ---
echo ">>> Building WAR..."
mvn -q clean package
WAR="target/${ARTIFACT_ID}.war"
[ -f "$WAR" ] || { echo "Build failed: WAR not found"; exit 1; }

# --- deploy ---
if [ -z "$TOMCAT_HOME" ]; then
  # package install path
  WEBAPPS_DIR="/var/lib/${TOMCAT_SVC}/webapps"
else
  WEBAPPS_DIR="${TOMCAT_HOME}/webapps"
fi
echo ">>> Deploying to ${WEBAPPS_DIR}..."
sudo cp -f "$WAR" "$WEBAPPS_DIR/"

# --- start/restart ---
if command -v systemctl >/dev/null; then
  echo ">>> Restarting ${TOMCAT_SVC}..."
  sudo systemctl restart "${TOMCAT_SVC}"
  sudo systemctl --no-pager --full status "${TOMCAT_SVC}" | sed -n '1,15p' || true
else
  echo "systemd not available; start Tomcat manually from ${TOMCAT_HOME}/bin/"
fi

echo "------------------------------------------------------------"
echo "URL         : http://localhost:8080/${ARTIFACT_ID}/"
echo "Project dir : $PROJECT_DIR"
echo "Tomcat home : ${TOMCAT_HOME:-/var/lib/${TOMCAT_SVC}}"
echo "WAR         : $WAR"
echo "------------------------------------------------------------"
