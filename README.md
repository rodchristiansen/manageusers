# ManageUsers Swift Binary

A comprehensive macOS user management tool built in Swift 6.1+ that replaces the original bash and Python scripts with a single, signed native binary.

## Features

### Core User Management
- **User Deletion**: Intelligent user deletion based on login and creation dates
- **Policy-Based Management**: Configurable deletion policies based on location/room settings
- **Simulation Mode**: Test operations safely without actual deletions
- **Force Mode**: Override time restrictions for immediate operations
- **Deferred Deletions**: Queue deletions when users are actively logged in

### Session Tracking
- **Login History**: Track user login sessions via utmpx
- **Creation Dates**: Multiple methods to detect account creation timestamps
- **Session Types**: Support for GUI, SSH, and combined session tracking
- **Plist Generation**: Compatible with existing workflow expectations

### Remediation Tools
- **SecureToken Management**: Check and manage SecureToken status
- **Orphan Cleanup**: Remove orphaned user records and home directories  
- **User Counting**: Count and list GUI vs directory service users
- **XCreds Integration**: Manage XCreds authentication system
- **Directory Cache**: Flush directory services cache

### System Integration
- **Full Disk Access**: Proper entitlements for system-level operations
- **Code Signing**: Support for signing and notarization
- **Logging**: Structured logging with rotation
- **Error Handling**: Comprehensive error reporting

## Installation

### Prerequisites
- macOS 12.0 or later
- Swift 6.0+ (for building from source)
- Xcode Command Line Tools

### Building from Source

1. Clone the repository:
```bash
git clone https://github.com/rodchristiansen/manageusers.git
cd manageusers
```

2. Configure signing (optional but recommended):
```bash
# Copy the environment template
cp .env.example .env

# Edit .env file with your signing information
# CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)"
# KEYCHAIN_PATH="${HOME}/Library/Keychains/signing.keychain"
```

3. Build the binary:
```bash
./build.sh
```

The build script will automatically use the `.env` configuration if present, or fall back to environment variables.

### Environment Configuration

The project supports a `.env` file for configuration. Key settings include:

```bash
# Code Signing (for distribution)
CODE_SIGN_IDENTITY="Developer ID Application: Emily Carr University of Art and Design (7TF6CSP83S)"
KEYCHAIN_PATH="${HOME}/Library/Keychains/signing.keychain"

# Optional: Keychain password (use with caution)
# KEYCHAIN_PASSWORD="your-keychain-password"

# Build settings
BUILD_CONFIGURATION="release"
TARGET_ARCHITECTURES="x86_64,arm64"
PKG_OUTPUT_PATH="./release"
```

**Security Note**: The `.env` file is excluded from version control to protect sensitive signing information. Always use `.env.example` as a template.

## Usage

### Basic Commands

```bash
# Delete users with simulation mode (safe testing)
ManageUsers delete --simulate

# Delete users in live mode (actual deletions)
ManageUsers delete --live

# Force immediate deletion (bypass time restrictions)
ManageUsers delete --force --live

# Generate user session data
ManageUsers sessions

# Check SecureToken status
ManageUsers remediate secure-token

# Count users
ManageUsers remediate count --list

# Clean up orphaned records
ManageUsers remediate cleanup-orphans --simulate
```

### Command Structure

The binary supports three main command groups:

#### 1. Delete Users (`delete`)
Primary user management functionality:
- `--simulate` / `-s`: Safe mode - no actual deletions
- `--force` / `-f`: Bypass time restrictions
- `--live` / `-l`: Perform actual deletions
- `--verbose` / `-v`: Detailed logging
- `--days N`: Override duration threshold
- `--exclusions-plist PATH`: Custom exclusions file
- `--strategy STRATEGY`: Deletion strategy (login-and-creation, creation-only)

#### 2. User Sessions (`sessions`)  
Session tracking and analysis:
- `--verbose` / `-v`: Detailed logging
- `--session-type TYPE`: Session type (gui, ssh, gui_ssh)
- `--output PATH`: Custom output plist path
- `--generate-only`: Only generate data, don't process users

#### 3. Remediation (`remediate`)
System maintenance tools:
- `secure-token [username]`: Check SecureToken status
- `cleanup-orphans --type TYPE`: Clean orphaned records/directories
- `count [--list]`: Count and optionally list users
- `list --filter TYPE`: List users with filtering
- `delete-all`: Delete all non-excluded users (DANGEROUS)
- `xcreds --action ACTION`: Manage XCreds system
- `flush-cache`: Flush directory services cache

## Configuration

### Exclusion Lists
Users are excluded from deletion based on:
1. Built-in system accounts: `root`, `admin`, `daemon`, etc.
2. Custom exclusions from UserSessions.plist
3. Currently logged-in user (automatically added)

### Deletion Policies
Policies are calculated based on Remote Desktop settings:
- **Library/DOC/CommDesign**: 2-day policy (creation dates only)
- **Photo/Illustration labs**: 30-day policy (creation dates only)  
- **FMSA/NMSA areas**: 6-week policy or immediate at end-of-term
- **Default**: 4-week policy (login and creation dates)

### End-of-Term Dates
Automatic detection of term boundaries:
- April 30 (Spring term end)
- August 31 (Summer term end)
- December 31 (Fall term end)

## Security

### Code Signing
The binary supports macOS code signing for deployment:
- Hardened Runtime enabled
- Entitlements for Full Disk Access
- Timestamp signing for longevity
- Notarization ready

### Permissions Required
- **Full Disk Access**: For user home directory operations
- **Admin Privileges**: For user account modifications
- **SecureToken Operations**: Via sysadminctl with admin credentials

## Compatibility

### Legacy Script Compatibility
The binary maintains compatibility with the original workflow:
- Reads existing UserSessions.plist format
- Supports same command-line patterns
- Writes logs to same locations
- Can be symlinked as drop-in replacement

### System Requirements
- macOS 12.0+ (Monterey or later)
- Intel or Apple Silicon Macs
- Admin privileges for user management operations

## Development

### Architecture
- **Swift 6.1**: Modern Swift with strict concurrency
- **ArgumentParser**: Command-line interface
- **Foundation**: Core system integration
- **OSLog**: System logging integration

### Key Components
- `UserManager`: Core deletion logic and policies
- `SessionTracker`: Login history and account creation tracking  
- `RemediationManager`: System maintenance operations
- `LoggingManager`: Structured logging with rotation

### Testing
```bash
# Run in simulation mode for safe testing
./release/ManageUsers delete --simulate --verbose

# Test specific remediation functions
./release/ManageUsers remediate count --list
./release/ManageUsers remediate secure-token
```

## Migration from Scripts

### From ManageUsers.sh
The Swift binary provides a superset of the original functionality:
- All command-line flags supported
- Enhanced error handling and logging
- Better performance and reliability
- Native macOS integration

### From UserSessions.py
Session tracking is now integrated:
- Same utmpx parsing logic
- Enhanced creation date detection
- Improved plist generation
- Better error recovery

## Troubleshooting

### Common Issues

1. **Permission Denied**: Ensure Full Disk Access is granted
2. **Admin Password**: Verify ManagedInstalls.plist contains SecureTokenAdmin
3. **Signature Issues**: Check code signing identity and team ID
4. **Build Failures**: Ensure Swift 6.0+ and Xcode tools are installed

### Debug Mode
Enable verbose logging for troubleshooting:
```bash
ManageUsers delete --simulate --verbose
```

### Log Locations
- Primary logs: `/Library/Management/Logs/ManageUsers.log`
- Session data: `/Library/Management/Cache/UserSessions.plist`
- Backup logs: `/Library/Management/Logs/ManageUsers.log.YYYYMMDDHHMMSS.bak`

## License

This project is provided under the same terms as the original Munki project.

## Support

For issues and feature requests, please use the GitHub issue tracker.