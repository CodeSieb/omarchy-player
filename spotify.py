#!/usr/bin/env python3
"""Spotify library helper: login | contains <id> | set <id> <true|false> | dj."""
import base64
import hashlib
import http.server
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID_FILE = os.path.expanduser("~/.config/omarchy-player/client_id")
REDIRECT_URI = "http://127.0.0.1:43117/callback"
SCOPES = "user-library-read user-library-modify user-read-playback-state"
TOKEN_URL = "https://accounts.spotify.com/api/token"
TOKEN_FILE = os.path.expanduser("~/.local/state/omarchy-player/spotify.json")
DJ_URI = "spotify:playlist:37i9dQZF1EYkqdzj48dyYq"
DEBUG_PORT = 9229
# Spotify's DJ switch has no API and no label: it's the bar button before Lyrics.
CLICK_DJ_SWITCH = """(() => {
  const lyrics = document.querySelector('[data-testid=lyrics-button]');
  const bar = lyrics && lyrics.closest('footer, aside, [data-testid=now-playing-bar]');
  if (!bar) return false;
  const buttons = [...bar.querySelectorAll('button')];
  const button = buttons[buttons.indexOf(lyrics) - 1];
  if (!button || button.getAttribute('aria-label')) return false;
  button.click();
  return true;
})()"""
FALLBACK_STATUSES = (403, 404, 410)


def save_token(payload):
    payload["expires_at"] = time.time() + payload.get("expires_in", 3600) - 60
    fd = os.open(TOKEN_FILE + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(payload, file)
    os.replace(TOKEN_FILE + ".tmp", TOKEN_FILE)


def client_id():
    try:
        with open(CLIENT_ID_FILE) as file:
            return file.read().strip()
    except FileNotFoundError:
        sys.exit(f"Put your Spotify app's client ID in {CLIENT_ID_FILE}")


def request_token(fields):
    body = urllib.parse.urlencode({"client_id": client_id(), **fields}).encode()
    with urllib.request.urlopen(TOKEN_URL, body, timeout=15) as response:
        return json.load(response)


def access_token():
    with open(TOKEN_FILE) as file:
        token = json.load(file)
    if time.time() < token["expires_at"]:
        return token["access_token"]
    fresh = request_token({"grant_type": "refresh_token", "refresh_token": token["refresh_token"]})
    fresh.setdefault("refresh_token", token["refresh_token"])
    save_token(fresh)
    return fresh["access_token"]


def api(method, path):
    request = urllib.request.Request(
        "https://api.spotify.com/v1" + path, method=method,
        headers={"Authorization": "Bearer " + access_token()})
    with urllib.request.urlopen(request, timeout=15) as response:
        data = response.read()
    return json.loads(data) if data else None


def library(method, track_id, suffix=""):
    uri = urllib.parse.quote("spotify:track:" + track_id)
    try:
        return api(method, f"/me/library{suffix}?uris={uri}")
    except urllib.error.HTTPError as error:
        if error.code not in FALLBACK_STATUSES:
            raise
    # Spotify has been moving these endpoints, so keep the older route as a fallback.
    return api(method, f"/me/tracks{suffix}?ids={track_id}")


def login():
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    result = {}

    class Callback(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if query.get("state", [""])[0] == state:
                result["code"] = query.get("code", [""])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Omarchy Player: you can close this tab.")

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 43117), Callback)
    server.timeout = 300
    url = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode({
        "client_id": client_id(), "response_type": "code", "redirect_uri": REDIRECT_URI,
        "scope": SCOPES, "state": state, "code_challenge_method": "S256",
        "code_challenge": challenge})
    subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("Waiting for approval in the browser...", flush=True)
    server.handle_request()
    if not result.get("code"):
        sys.exit("Login was not completed.")
    save_token(request_token({"grant_type": "authorization_code", "code": result["code"],
                              "redirect_uri": REDIRECT_URI, "code_verifier": verifier}))
    print("Logged in.")


def player_call(method, *args):
    subprocess.run(["gdbus", "call", "--session", "-d", "org.mpris.MediaPlayer2.spotify",
                    "-o", "/org/mpris/MediaPlayer2", "-m", "org.mpris.MediaPlayer2.Player." + method,
                    *args], stdout=subprocess.DEVNULL)


def evaluate_in_spotify(expression):
    """Run JS in Spotify through its local debug port, over a minimal WebSocket."""
    url = f"http://127.0.0.1:{DEBUG_PORT}/json"
    with urllib.request.urlopen(url, timeout=3) as response:
        pages = [t for t in json.load(response) if "xpui" in t.get("url", "")]
    path = pages[0]["webSocketDebuggerUrl"].split(str(DEBUG_PORT), 1)[1]
    with socket.create_connection(("127.0.0.1", DEBUG_PORT), timeout=3) as sock:
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{DEBUG_PORT}\r\n"
                      "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        reply = b""
        while b"\r\n\r\n" not in reply:
            reply += sock.recv(4096)
        message = json.dumps({"id": 1, "method": "Runtime.evaluate",
                              "params": {"expression": expression}}).encode()
        mask = os.urandom(4)
        length = bytes([0xFE]) + struct.pack(">H", len(message)) if len(message) > 125 \
            else bytes([0x80 | len(message)])
        sock.sendall(b"\x81" + length + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(message)))
        reply = b""
        while b'"result"' not in reply or not reply.rstrip().endswith(b"}"):
            reply += sock.recv(4096)
    return b'"value":true' in reply


def dj():
    try:
        context = (api("GET", "/me/player") or {}).get("context") or {}
    except Exception:
        context = {}
    if context.get("uri") == DJ_URI:
        try:
            if evaluate_in_spotify(CLICK_DJ_SWITCH):
                return
        except Exception:
            pass
        # Reopening DJ restarts it, so skip when the switch can't be reached.
        player_call("Next")
    else:
        player_call("OpenUri", DJ_URI)


def main():
    command = sys.argv[1]
    if command == "login":
        login()
    elif command == "contains":
        try:
            print("true" if library("GET", sys.argv[2], "/contains")[0] else "false")
        except Exception:
            print("unavailable")
    elif command == "dj":
        dj()
    elif command == "set":
        library("PUT" if sys.argv[3] == "true" else "DELETE", sys.argv[2])


if __name__ == "__main__":
    main()
