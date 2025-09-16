#!/bin/bash
set -e

# Build configuration for ManageUsers Swift binary
PRODUCT_NAME="ManageUsers"
BUILD_DIR="$(pwd)/.build"
RELEASE_DIR="$(pwd)/release"
ENTITLEMENTS_FILE="$(pwd)/ManageUsers.entitlements"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
TEAM_ID="${DEVELOPMENT_TEAM}"

echo "Building $PRODUCT_NAME..."

# Clean previous builds
rm -rf "$BUILD_DIR"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Build the Swift package in release mode
echo "Compiling Swift package..."
swift build -c release --arch arm64 --arch x86_64

# Check if binary was built
BINARY_PATH="$BUILD_DIR/apple/Products/Release/ManageUsers"
if [[ ! -f "$BINARY_PATH" ]]; then
    BINARY_PATH="$BUILD_DIR/release/ManageUsers"
fi

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "Error: Binary not found after build"
    exit 1
fi

echo "Binary built successfully at: $BINARY_PATH"

# Copy binary to release directory
cp "$BINARY_PATH" "$RELEASE_DIR/"

# Sign the binary if identity is provided
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "Developer ID Application" ]]; then
    echo "Signing binary with identity: $SIGNING_IDENTITY"
    
    # Sign with entitlements for full disk access
    codesign --force \
        --options runtime \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$ENTITLEMENTS_FILE" \
        --timestamp \
        "$RELEASE_DIR/$PRODUCT_NAME"
    
    echo "Binary signed successfully"
    
    # Verify signature
    echo "Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "$RELEASE_DIR/$PRODUCT_NAME"
    
    # Display signature info
    echo "Signature information:"
    codesign --display --verbose=4 "$RELEASE_DIR/$PRODUCT_NAME"
    
else
    echo "No signing identity provided - binary will not be signed"
    echo "To sign, set CODE_SIGN_IDENTITY environment variable"
fi

# Create installation package structure
PKG_ROOT="$RELEASE_DIR/pkg-root"
mkdir -p "$PKG_ROOT/usr/local/bin"
mkdir -p "$PKG_ROOT/Library/Management/Scripts"

# Copy binary to package structure
cp "$RELEASE_DIR/$PRODUCT_NAME" "$PKG_ROOT/usr/local/bin/"
chmod +x "$PKG_ROOT/usr/local/bin/$PRODUCT_NAME"

# Create compatibility symlinks for existing workflow
ln -sf "/usr/local/bin/$PRODUCT_NAME" "$PKG_ROOT/Library/Management/Scripts/ManageUsers.sh"

echo "Build completed successfully!"
echo "Binary location: $RELEASE_DIR/$PRODUCT_NAME"
echo "Package root: $PKG_ROOT"

# Display binary information
echo ""
echo "Binary information:"
file "$RELEASE_DIR/$PRODUCT_NAME"
ls -la "$RELEASE_DIR/$PRODUCT_NAME"

# Test basic functionality
echo ""
echo "Testing binary..."
"$RELEASE_DIR/$PRODUCT_NAME" --help || echo "Help command failed - this is expected if dependencies aren't resolved"