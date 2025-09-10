#!/bin/bash

# Maven Java Automation Script with GitHub Download
# This script downloads the latest files from GitHub repository,
# sets up the project structure, compiles and runs the Java application

echo "Maven Java Automation with GitHub Download"
echo "=============================================="

# Repository information
REPO_OWNER="divyamohan1993"
REPO_NAME="maven-java-automation"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}"

# Create project structure if not present
echo "Setting up project structure..."
mkdir -p src/main/java/com/example
mkdir -p src/test/java
mkdir -p target

# Download pom.xml
echo "Downloading pom.xml..."
curl -L -o pom.xml "${BASE_URL}/pom.xml"
if [ $? -ne 0 ]; then
    echo "Error: Failed to download pom.xml"
    exit 1
fi

# Download Java source files
echo "Downloading Java source files..."
# Check if src directory exists in repository and download recursively
curl -L -s "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/src/main/java" | \
grep -o '"download_url":"[^"]*\.java"' | \
sed 's/"download_url":"//' | \
sed 's/"//' | \
while read -r url; do
    if [ ! -z "$url" ]; then
        # Extract the relative path from the URL
        relative_path=$(echo "$url" | sed "s|${BASE_URL}/||")
        # Create directory structure
        mkdir -p "$(dirname "$relative_path")"
        echo "Downloading $relative_path..."
        curl -L -o "$relative_path" "$url"
        if [ $? -ne 0 ]; then
            echo "Warning: Failed to download $relative_path"
        fi
    fi
done

# Alternative approach if API method fails - download specific known files
if [ ! -f "src/main/java/com/example/App.java" ]; then
    echo "Attempting direct download of main application files..."
    curl -L -o "src/main/java/com/example/App.java" "${BASE_URL}/src/main/java/com/example/App.java" 2>/dev/null
fi

# Check if Maven is installed
if ! command -v mvn &> /dev/null; then
    echo "Error: Maven is not installed. Please install Maven first."
    exit 1
fi

echo "Downloaded files successfully!"
echo "Project structure:"
find . -name "*.java" -o -name "pom.xml" | sort

echo ""
echo "Compiling the project..."
# Clean and compile the project
mvn clean compile

if [ $? -eq 0 ]; then
    echo "Compilation successful!"
    echo ""
    echo "Running the application..."
    # Run the main class
    mvn exec:java -Dexec.mainClass="com.example.App"
else
    echo "Compilation failed. Please check the error messages above."
    exit 1
fi

echo ""
echo "Maven Java Automation completed successfully!"
echo "=========================================="