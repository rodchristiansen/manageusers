#!/Library/ManagedFrameworks/Python/Python3.framework/Versions/Current/bin/python3

import subprocess
import plistlib
import os
import logging
import sys
from ctypes import (CDLL, Structure, POINTER, c_int64, c_int32, c_int16, c_char, c_uint32)
from ctypes.util import find_library

# Constants
BOOT_TIME = 2
USER_PROCESS = 7
DEAD_PROCESS = 8
SHUTDOWN_TIME = 11

# Log file path
LOG_DIR = '/Library/Management/Logs'
LOG_FILE = os.path.join(LOG_DIR, 'UserSessions.log')

# Exclusion List (Customizable)
CUSTOM_EXCLUDE_USERS = [
    "admin",
    "doc",
    "cts",
    "fvim",
    "fmsa"
]

# Ensure the Logs directory exists
def ensure_log_directory(path):
    if not os.path.exists(path):
        try:
            os.makedirs(path, exist_ok=True)
            print(f"Created log directory: {path}")
        except PermissionError as e:
            print(f"Permission denied while creating log directory: {e}")
            sys.exit(1)
        except Exception as e:
            print(f"Failed to create log directory: {e}")
            sys.exit(1)

# Setup logging
def setup_logging():
    ensure_log_directory(LOG_DIR)
    logging.basicConfig(
        filename=LOG_FILE,
        level=logging.DEBUG,
        format='%(asctime)s %(levelname)s:%(message)s'
    )
    logging.info("Logging initialized.")

# Define the structures
class timeval(Structure):
    _fields_ = [
        ("tv_sec", c_int64),  # seconds since the epoch
        ("tv_usec", c_int32),  # microseconds
    ]

class utmpx(Structure):
    _fields_ = [
        ("ut_user", c_char*256),
        ("ut_id", c_char*4),
        ("ut_line", c_char*32),
        ("ut_pid", c_int32),
        ("ut_type", c_int16),
        ("ut_tv", timeval),
        ("ut_host", c_char*256),
        ("ut_pad", c_uint32*16),
    ]

# Function to get UID of a user
def get_uid(username):
    try:
        cmd = ['/usr/bin/id', '-u', username]
        proc = subprocess.Popen(cmd, shell=False, bufsize=-1,
                                stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (output, unused_error) = proc.communicate()
        output = output.decode("utf-8", errors="ignore").strip()
        logging.debug(f"UID for user {username}: {output}")
        return output
    except Exception as e:
        logging.error(f"Error getting UID for user {username}: {e}")
        return None

# Function to replicate the functionality of /usr/bin/last
def fast_last(session='gui_ssh'):
    """Replicates /usr/bin/last command to output all logins, reboots, and shutdowns."""
    logging.info("Starting fast_last function")
    
    try:
        # Load the system library
        c = CDLL(find_library("System"))
        logging.debug("Loaded System library successfully.")
    except Exception as e:
        logging.error(f"Error loading system library: {e}")
        return []

    # Define ctypes functions for reading log entries
    try:
        setutxent_wtmp = c.setutxent_wtmp
        setutxent_wtmp.restype = None
        getutxent_wtmp = c.getutxent_wtmp
        getutxent_wtmp.restype = POINTER(utmpx)
        endutxent_wtmp = c.endutxent_wtmp
        endutxent_wtmp.restype = None
        logging.debug("CTypes functions set up successfully.")
    except AttributeError as e:
        logging.error(f"Error setting up utmpx functions: {e}")
        return []

    # Data storage for log events
    events = []

    try:
        # Initialize the reading of log entries
        setutxent_wtmp(0)
        logging.debug("Initialized utmpx reading.")

        while True:
            entry = getutxent_wtmp()
            if not entry:
                break
            e = entry.contents
            event = {}
            if e.ut_type == BOOT_TIME:
                # Reboot/startup
                event = {'event': 'reboot', 'time': e.ut_tv.tv_sec}
                logging.debug(f"Detected reboot at {e.ut_tv.tv_sec}.")
            elif e.ut_type == SHUTDOWN_TIME:
                # Shutdown
                event = {'event': 'shutdown', 'time': e.ut_tv.tv_sec}
                logging.debug(f"Detected shutdown at {e.ut_tv.tv_sec}.")
            elif (e.ut_type == USER_PROCESS) or (e.ut_type == DEAD_PROCESS):
                event_label = 'login' if e.ut_type == USER_PROCESS else 'logout'

                if session == 'gui' and e.ut_line.decode("utf-8", errors="ignore") != "console":
                    continue
                if (session == 'gui_ssh' and e.ut_host.decode("utf-8", errors="ignore") == "") and (
                        e.ut_line.decode("utf-8", errors="ignore") != "console"):
                    continue

                username = e.ut_user.decode("utf-8", errors="ignore").strip()

                # Exclude specific users
                # System exclusions are hard-coded here, custom exclusions will be managed externally
                if username in ['_mbsetupuser', 'root'] + CUSTOM_EXCLUDE_USERS:
                    continue

                event = {
                    'event': event_label,
                    'user': username,
                    'time': e.ut_tv.tv_sec  # Store the time in epoch format
                }

                if username:
                    uid = get_uid(username)
                    if uid:
                        event['uid'] = uid
                if e.ut_host.decode("utf-8", errors="ignore").strip():
                    event['remote_ssh'] = e.ut_host.decode("utf-8", errors="ignore").strip()

                logging.debug(f"Recorded event: {event}")

            if event:
                events.append(event)

    except Exception as e:
        logging.error(f"Error processing utmpx entries: {e}")
    finally:
        # Finish reading log entries
        endutxent_wtmp()
        logging.info("Finished reading utmpx entries.")

    logging.debug(f"Total events collected: {len(events)}")
    return events

def main():
    """Main"""
    setup_logging()
    logging.info("Starting UserSessions.py")
    try:
        # Get results from fast_last function
        result = fast_last()
        logging.debug(f"fast_last() returned {len(result)} events.")

        # Dictionary to store last sign-in times
        user_signin_log = {}

        # Get current users from /Users directory
        current_users = [d for d in os.listdir('/Users') if not d.startswith('_')]
        logging.debug(f"Current users: {current_users}")

        # Process the result to find the last login time for each user
        for event in result:
            if event.get('event') == 'login':
                username = event.get('user')
                last_login_time = event.get('time')

                # Only log users who still exist in /Users directory
                if username in current_users:
                    if username in user_signin_log:
                        if last_login_time > user_signin_log[username]:
                            user_signin_log[username] = last_login_time
                            logging.debug(f"Updated last login for {username}: {last_login_time}")
                    else:
                        user_signin_log[username] = last_login_time
                        logging.debug(f"Recorded first login for {username}: {last_login_time}")

        logging.debug(f"User sign-in log: {user_signin_log}")

        # Define exclusion list to be included in the plist
        exclusion_list = CUSTOM_EXCLUDE_USERS

        # Combined data to write to plist
        combined_data = {
            'Users': user_signin_log,
            'Exclusions': exclusion_list
        }

        # Write combined data to the specified plist
        output_plist = '/Library/Management/ca.ecuad.macadmin.UserSessions.plist'
        try:
            with open(output_plist, 'wb') as fp:
                plistlib.dump(combined_data, fp, fmt=plistlib.FMT_XML)
            logging.info(f"Successfully wrote combined plist to {output_plist}")
        except Exception as e:
            logging.error(f"Failed to write plist: {e}")
            sys.exit(1)

    except Exception as e:
        logging.error(f"An error occurred in main: {e}")
        sys.exit(1)

    logging.info("UserSessions.py completed successfully.")

if __name__ == "__main__":
    main()
