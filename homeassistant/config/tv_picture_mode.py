#!/usr/bin/env python3
"""Set the TV's picture mode through the SmartThings cloud (HA shell_command).

Usage: tv_picture_mode.py "Standard" | "Movie" | "FILMMAKER MODE"
       tv_picture_mode.py --check   (exit 3 if HA's SmartThings token has expired)
       tv_picture_mode.py --read    (print the TV's current picture mode; exit 3 = token expired)
HA's core SmartThings integration sees the TV but has no picture-mode control, while the
TV itself offers custom.picturemode. This borrows the integration's OAuth access token
from .storage (HA keeps it fresh; script.tv_picture_mode polls the TV first so HA
refreshes an old token) and never prints it. Exit 0 = the TV reports the new mode;
exit 3 = the token is expired or refused (HA once stopped renewing it): the
caller reloads the SmartThings integration, which renews it, and retries.
"""
import json, sys, time, urllib.error, urllib.request

TV = "00000000-0000-0000-0000-000000000000"  # SmartThings device id of the TV (placeholder)
API = "https://api.smartthings.com/v1/devices/" + TV
mode = sys.argv[1] if len(sys.argv) > 1 else ""

entries = json.load(open("/config/.storage/core.config_entries"))["data"]["entries"]
tok = next(e for e in entries if e["domain"] == "smartthings")["data"]["token"]
if tok.get("expires_at", 0) < time.time() + 60:
    print("SmartThings token expired")
    sys.exit(3)
if mode == "--check":
    sys.exit(0)
token = tok["access_token"]
H = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
REFRESH = {"commands": [{"component": "main", "capability": "refresh", "command": "refresh"}]}


def call(path="", body=None):
    req = urllib.request.Request(API + path, headers=H, method="POST" if body else "GET",
                                 data=json.dumps(body).encode() if body else None)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


try:
    if mode == "--read":
        call("/commands", REFRESH)
        time.sleep(2)
        print(call("/components/main/capabilities/custom.picturemode/status")["pictureMode"]["value"])
        sys.exit(0)
    call("/commands", REFRESH)  # the cloud's pictureMode is stale until the TV is refreshed
    time.sleep(2)
    status = call("/components/main/capabilities/custom.picturemode/status")
    supported = status["supportedPictureModes"]["value"]
    if mode not in supported:
        sys.exit(f"unknown mode {mode!r}; TV offers {supported}")
    if status["pictureMode"]["value"] == mode:
        print(f"already {mode}")
        sys.exit(0)
    call("/commands", {"commands": [{"component": "main", "capability": "custom.picturemode",
                                     "command": "setPictureMode", "arguments": [mode]}]})
    for _ in range(4):
        time.sleep(2)
        call("/commands", REFRESH)
        time.sleep(1)
        now = call("/components/main/capabilities/custom.picturemode/status")["pictureMode"]["value"]
        if now == mode:
            print(f"set {mode}")
            sys.exit(0)
    sys.exit(f"sent {mode}, TV still reports {now}")
except urllib.error.HTTPError as e:
    print(f"SmartThings HTTP {e.code}")
    sys.exit(3 if e.code == 401 else 1)
except urllib.error.URLError as e:
    sys.exit(f"SmartThings unreachable: {e.reason}")
