#!/bin/bash

# Maven Java Automation Build and Run Script
# This script compiles and runs the Maven Java project

echo "Starting Maven Java Automation..."
echo "==================================="

# Check if Maven is installed
if ! command -v mvn &> /dev/null; then
    echo "Error: Maven is not installed or not in PATH"
    echo "Please install Maven and try again"
    exit 1
fi

echo "Maven version:"
mvn --version
echo ""

# Clean and compile the project
echo "Cleaning and compiling the project..."
mvn clean compile

if [ $? -ne 0 ]; then
    echo "Error: Compilation failed"
    exit 1
fi

echo "Compilation successful!"
echo ""

# Run the application
echo "Running the application..."
echo "========================"
mvn exec:java -Dexec.mainClass="com.example.App"

echo ""
echo "Script completed successfully!"
echo "============================="
