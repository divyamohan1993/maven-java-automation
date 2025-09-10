#!/usr/bin/env bash
# oneclick-webapp.sh — create, build, and deploy a Maven webapp to Tomcat
# Works on Ubuntu/Debian (incl. WSL with systemd enabled). Idempotent.

set -euo pipefail

# ---- Config (change if you want) ----
GROUP_ID="com.example"
ARTIFACT_ID="hello-web"
VERSION="1.0.0"
JAVA_RELEASE="17"
ARCHETYPE_VERSION="1.4"
PROJECT_DIR="$PWD/$ARTIFACT_ID"

echo ">>> Starting one-click Maven webapp setup..."

# ---- 0) Package manager + base deps ----
if command -v apt-get >/dev/null 2>&1; then
  PM="apt-get"
else
  echo "This script currently supports Debian/Ubuntu (apt-get)."
  exit 1
fi

echo ">>> Installing Java, Maven, and Tomcat (requires sudo)..."
sudo $PM update -y
sudo $PM install -y openjdk-17-jdk maven

# Tomcat installation with improved fallback support
TOMCAT_SVC=""
TOMCAT_HOME=""

# Try to install Tomcat 10 first (more widely available and up-to-date)
if apt-cache policy tomcat10 | grep -q Candidate; then
  echo ">>> Installing Tomcat 10 from package repository..."
  sudo $PM install -y tomcat10
  TOMCAT_SVC="tomcat10"
  TOMCAT_HOME="/var/lib/tomcat10"
elif apt-cache policy tomcat9 | grep -q Candidate; then
  echo ">>> Installing Tomcat 9 from package repository..."
  sudo $PM install -y tomcat9
  TOMCAT_SVC="tomcat9"
  TOMCAT_HOME="/var/lib/tomcat9"
else
  echo ">>> Neither tomcat9 nor tomcat10 available in package repository."
  echo ">>> Installing Tomcat 10 manually..."
  
  # Manual Tomcat installation
  TOMCAT_VERSION="10.1.24"
  TOMCAT_SVC="tomcat10"
  TOMCAT_HOME="/opt/tomcat"
  
  # Create tomcat user if not exists
  if ! id "tomcat" &>/dev/null; then
    sudo useradd -r -m -U -d /opt/tomcat -s /bin/false tomcat
  fi
  
  # Download and install Tomcat
  cd /tmp
  if [ ! -f "apache-tomcat-${TOMCAT_VERSION}.tar.gz" ]; then
    echo ">>> Downloading Tomcat ${TOMCAT_VERSION}..."
    wget -q "https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
  fi
  
  # Extract and setup
  if [ ! -d "$TOMCAT_HOME" ]; then
    sudo mkdir -p "$TOMCAT_HOME"
    sudo tar -xzf "apache-tomcat-${TOMCAT_VERSION}.tar.gz" -C "$TOMCAT_HOME" --strip-components=1
    sudo chown -R tomcat:tomcat "$TOMCAT_HOME"
    sudo chmod +x "$TOMCAT_HOME/bin/"*.sh
  fi
  
  # Create systemd service file
  sudo tee /etc/systemd/system/tomcat10.service > /dev/null <<EOF
[Unit]
Description=Apache Tomcat 10
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment=JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
Environment=CATALINA_PID=${TOMCAT_HOME}/temp/tomcat.pid
Environment=CATALINA_HOME=${TOMCAT_HOME}
Environment=CATALINA_BASE=${TOMCAT_HOME}
Environment=CATALINA_OPTS=-Xms512M -Xmx1024M -server -XX:+UseParallelGC
ExecStart=${TOMCAT_HOME}/bin/startup.sh
ExecStop=${TOMCAT_HOME}/bin/shutdown.sh
RestartSec=10
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  
  # Enable and start service
  sudo systemctl daemon-reload
  sudo systemctl enable tomcat10
  
  echo ">>> Manual Tomcat 10 installation completed."
fi

# ---- 1) Generate Maven webapp project (idempotent) ----
if [ ! -d "$PROJECT_DIR" ]; then
  echo ">>> Generating Maven webapp project: $ARTIFACT_ID"
  mvn archetype:generate \
    -DgroupId="$GROUP_ID" \
    -DartifactId="$ARTIFACT_ID" \
    -DarchetypeArtifactId=maven-archetype-webapp \
    -DarchetypeVersion="$ARCHETYPE_VERSION" \
    -DinteractiveMode=false
else
  echo ">>> Project already exists at $PROJECT_DIR (skipping generate)"
fi

cd "$PROJECT_DIR"

# ---- 2) Write Tomcat-compatible POM (jakarta for Tomcat 10, javax for Tomcat 9) ----
if [ "$TOMCAT_SVC" = "tomcat9" ]; then
  SERVLET_COORD='javax.servlet
      javax.servlet-api
      4.0.1'
else
  SERVLET_COORD='jakarta.servlet
      jakarta.servlet-api
      5.0.0'
fi

cat > pom.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
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
    <dependency>
      ${SERVLET_COORD}
      <scope>provided</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.11.0</version>
        <configuration>
          <release>\${maven.compiler.release}</release>
        </configuration>
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

# Ensure there's a minimal index.jsp
mkdir -p src/main/webapp
if [ ! -f src/main/webapp/index.jsp ]; then
  cat > src/main/webapp/index.jsp <<'JSP'
<%@ page contentType="text/html; charset=UTF-8" %>
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<title>Hello Web</title>
</head>
<body>
<h1>It works! 🎉</h1>
<p>Deployed via oneclick-webapp.sh</p>
</body>
</html>
JSP
fi

# ---- 3) Build WAR ----
echo ">>> Building WAR..."
mvn -q clean package
WAR="target/${ARTIFACT_ID}.war"
[ -f "$WAR" ] || { echo "Build failed: WAR not found"; exit 1; }

# ---- 4) Deploy to Tomcat ----
if [ -n "$TOMCAT_HOME" ]; then
  WEBAPPS_DIR="${TOMCAT_HOME}/webapps"
else
  # Fallback for package installations
  if [ "$TOMCAT_SVC" = "tomcat9" ]; then
    WEBAPPS_DIR="/var/lib/tomcat9/webapps"
  else
    WEBAPPS_DIR="/var/lib/tomcat10/webapps"
  fi
fi

echo ">>> Deploying to ${TOMCAT_SVC} (${WEBAPPS_DIR})..."
sudo cp -f "$WAR" "$WEBAPPS_DIR/"

# Restart Tomcat (systemd required; WSL needs systemd enabled)
if command -v systemctl >/dev/null 2>&1; then
  echo ">>> Restarting ${TOMCAT_SVC}..."
  sudo systemctl restart "$TOMCAT_SVC"
  
  # Check if service started successfully
  if sudo systemctl is-active --quiet "$TOMCAT_SVC"; then
    echo ">>> ${TOMCAT_SVC} started successfully"
  else
    echo ">>> Warning: ${TOMCAT_SVC} may not have started properly"
    echo ">>> Check status with: sudo systemctl status ${TOMCAT_SVC}"
  fi
else
  echo "systemctl not found. If running WSL without systemd, start Tomcat manually."
  if [ -n "$TOMCAT_HOME" ]; then
    echo "Manual start: sudo -u tomcat ${TOMCAT_HOME}/bin/startup.sh"
  fi
fi

# ---- 5) Final info ----
CTX="/${ARTIFACT_ID}/"
echo "------------------------------------------------------------"
echo "Deployed: http://localhost:8080${CTX}"
echo "Project dir: $PROJECT_DIR"
echo "Tomcat svc : $TOMCAT_SVC"
echo "Tomcat home: $TOMCAT_HOME"
echo "WAR file   : $WAR"
echo "------------------------------------------------------------"
