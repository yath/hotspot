hotspot
=======

Script for registering into a T-Mobile hotspot

Usage
-----
- Put a configuration file (see the sample one) hotspot.conf into /etc
- To register on the hotspot, run the script with the interface as command-line argument (or put it
  into the configuration file)
- Pass '-f' to fork into the background after initial registration
- Pass '-k' to kill the running background process
- Pass '-l' to log out and kill the running background process (This is currently broken)

Caveats
-------
- This script will terminate itself when it detects an "invalid" ESSID (i.e. is not known to be a T-Mobile
  hotspot). You may adjust the list of valid ESSIDS in the configuration file.
- By default, the script will re-login every five minutes to prevent the "idle timeout" catching. This may
  be adjusted in the config as well.
