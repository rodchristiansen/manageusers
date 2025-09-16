#!/bin/bash

# Setup script for ManageUsers development environment
# Configures signing and development environment

set -e

echo "ManageUsers Development Environment Setup"
echo "========================================"

# Check if .env file exists
if [[ -f ".env" ]]; then
    echo "Found existing .env file. Backing up as .env.backup"
    cp .env .env.backup
fi

# Copy template
cp .env.example .env
echo "Created .env file from template"

echo ""
echo "Please edit the .env file with your specific configuration:"
echo ""
echo "1. Set CODE_SIGN_IDENTITY to your Developer ID Application"
echo "2. Set KEYCHAIN_PATH to your signing keychain location" 
echo "3. Optionally set KEYCHAIN_PASSWORD (or leave empty for manual unlock)"
echo ""
echo "Emily Carr University example:"
echo 'CODE_SIGN_IDENTITY="Developer ID Application: Emily Carr University of Art and Design (7TF6CSP83S)"'
echo 'KEYCHAIN_PATH="${HOME}/Library/Keychains/signing.keychain"'
echo ""

# Check if signing identity is available
echo "Checking available signing identities..."
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo ""
    echo "Available Developer ID Application certificates:"
    security find-identity -v -p codesigning | grep "Developer ID Application" || echo "None found"
else
    echo "No Developer ID Application certificates found in default keychain"
    echo "You may need to install your certificate or specify the correct keychain"
fi

echo ""
echo "Setup complete! Edit .env file and then run:"
echo "  ./build.sh"
echo ""
echo "For help with signing setup, see:"
echo "  https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution"