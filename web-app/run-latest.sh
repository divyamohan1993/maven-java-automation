#!/bin/bash

# run-latest.sh
# Downloads the latest autoconfig.sh from GitHub, makes it executable, and runs it

set -e

# URL for autoconfig.sh from main branch
URL="https://raw.githubusercontent.com/divyamohan1993/maven-java-automation/refs/heads/main/web-app/autoconfig.sh"

# Generate cache-busting timestamp
TIMESTAMP=$(date +%s)

# Download autoconfig.sh with cache-busting
echo "Downloading latest autoconfig.sh..."
curl -fsSL "${URL}?t=${TIMESTAMP}" -o autoconfig.sh

# Make it executable
echo "Making autoconfig.sh executable..."
chmod +x autoconfig.sh

# Run it
echo "Running autoconfig.sh..."
./autoconfig.sh