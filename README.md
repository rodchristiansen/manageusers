*ManageUsers* is a lightweight Swift-based set of scripts designed to assist Mac Admins in managing user accounts.


## Installation

1. **Clone the Repository**

   Begin by cloning the repository to your local machine:

   ```bash
   git clone https://github.com/your-username/manageusers.git
   cd manageusers
   ```

2. **Ensure Python Script is Executable**

   The project includes a Python script to generate the necessary plist. Make sure it's executable:

   ```bash
   sudo chmod +x ./UserSessions.py
   ```


## Building the Application

To build the **ManageUsers** Swift script, follow these steps:

1. **Build in Release Mode**

   Navigate to the project directory and build the application:

   ```bash
   swift build -c release
   ```

2. **Locate the Binary**

   The compiled binary will be located at:

   ```
   ./manageusers
   ```

## Usage

Run the application with `sudo` and specify the duration for inactivity.

```bash
sudo ./manageusers --duration [1|4]
```

### Command-Line Flags

- `--duration`: Specifies the inactivity threshold.
  - `1`: Represents **1 week**
  - `4`: Represents **4 weeks**

### Examples

- **Delete users inactive for 1 week:**

  ```bash
  sudo ./manageusers --duration 1
  ```

- **Delete users inactive for 4 weeks:**

  ```bash
  sudo ./manageusers --duration 4
  ```

- **Attempting to run without specifying duration:**

  ```bash
  sudo ./manageusers
  ```

  **Expected Output:**

  ```
  [2024-04-27 10:00:00] Duration not specified. Usage: ManageUsers --duration [1|4]
  ```



## Configuration

The application uses a single plist file to manage user sessions and exclusions.

### Integrated `UserSessions.plist` Structure

Located at `/Library/Management/ca.ecuad.macadmin.UserSessions.plist`, the plist contains two main sections:

1. **Users**: Contains user session information.
2. **Exclusions**: Contains the exclusion list.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Users</key>
    <dict>
        <key>johndoe</key>
        <integer>1617187200</integer>
        <!-- Additional users -->
    </dict>
    <key>Exclusions</key>
    <array>
        <string>admin</string>
        <string>doc</string>
        <string>cts</string>
        <string>fvim</string>
        <string>fmsa</string>
    </array>
</dict>
</plist>
```

### Managing Exclusions

- **Adding a User:**
  - Add a new `<string>` element within the `<array>` under the `Exclusions` key.
  
- **Removing a User:**
  - Delete the corresponding `<string>` element from the plist file.

### Generating the Plist

Use the provided Python script to generate or update the plist:

```bash
sudo ./UserSessions.py
```

Ensure that the script has the necessary permissions and is executable.

---

## Logging

All actions and events are logged to `/Library/Management/Logs/ManageUsers.log`. The log includes:

- **User Processing Details**: Information about each user being processed.
- **Deletion Actions**: Logs indicating successful deletions or failures.
- **Cleanup Operations**: Details about orphaned user record cleanups.
- **Cache Flushing Results**: Status of Directory Services cache flushing.
- **Errors and Warnings**: Any issues encountered during execution.

**Sample Log Entry:**

```
[2024-04-27 10:00:00] ===== ManageUsers started =====
[2024-04-27 10:00:01] Selected duration: 4 week(s)
[2024-04-27 10:00:02] Processing user: 'johndoe' with last login time: '1617187200'
[2024-04-27 10:00:02] User 'johndoe' has not logged in for more than 4 week(s). Initiating deletion.
[2024-04-27 10:00:03] Successfully deleted user via sysadminctl: 'johndoe'
[2024-04-27 10:00:04] Successfully deleted user via dscl: 'johndoe'
[2024-04-27 10:00:04] Successfully removed FileVault credentials for user: 'johndoe'
[2024-04-27 10:00:04] Verification SUCCESS: User 'johndoe' has been deleted.
[2024-04-27 10:00:04] ------------------------------------------------------------
[2024-04-27 10:00:05] Starting cleanup of orphaned user records (users without home directories).
[2024-04-27 10:00:06] User 'janedoe' has no home directory at ''. Attempting to delete record...
[2024-04-27 10:00:06] Successfully deleted user via sysadminctl: 'janedoe'
[2024-04-27 10:00:07] Successfully deleted user via dscl: 'janedoe'
[2024-04-27 10:00:07] Verification SUCCESS: User 'janedoe' has been deleted.
[2024-04-27 10:00:07] ------------------------------------------------------------
[2024-04-27 10:00:08] Flushing Directory Services cache.
[2024-04-27 10:00:08] Successfully flushed Directory Services cache.
[2024-04-27 10:00:09] ===== ManageUsers completed =====
```

---

## Python Script Overview

### **Purpose**

The `UserSessions.py` Python script prepares the data required by the **ManageUsers** Swift tool. It performs the following functions:

1. **Collects User Session Data**:
   - Retrieves information about user logins, including the last login times.
   - Identifies currently active users on the system.

2. **Manages User Exclusions**:
   - Defines a customizable exclusion list to protect specific user accounts from being processed or deleted.
   - Integrates both system-level exclusions and custom exclusions into a single plist.

3. **Generates `UserSessions.plist`**:
   - Consolidates user session data and exclusion lists into a single Property List (`plist`) file.
   - Ensures that the Swift tool has access to up-to-date information for accurate processing.

### **Functionality**

- **User Session Tracking**:
  - Emulates the `/usr/bin/last` command to gather user login and logout events.
  - Filters out system users and those specified in the exclusion list.
  - Records the most recent login time for each user.

- **Exclusion List Integration**:
  - Combines hard-coded system exclusions with a customizable list of user exclusions.
  - Allows administrators to easily modify which users should be exempt from management actions.

- **Plist Generation**:
  - Writes the collected user session data and exclusion lists into `/Library/Management/ca.ecuad.macadmin.UserSessions.plist`.
  - Ensures the plist is in XML format for compatibility with the Swift application.

### **Dependency**

The **ManageUsers** Swift tool relies on the `UserSessions.plist` generated by this Python script. Before running the Swift application, ensure that the Python script has been executed to provide the necessary data.

### **Running the Python Script**

To execute the Python script and generate the plist:

```bash
sudo ./UserSessions.py
```

Ensure that the script has the appropriate permissions and that Python 3 is correctly installed on your system.

**Note**: The script should be scheduled to run periodically (e.g., via `cron` or `launchd`) to keep the plist updated with the latest user session information.
