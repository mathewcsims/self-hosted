import sys
import urllib.parse
import urllib.request

# Reads one Apprise-scheme notification URL (e.g. discord://id/token/) from
# stdin and registers it under the "self-hosted" config key so anything on
# the LAN can POST to /notify/self-hosted without knowing the underlying
# webhook. Invoked from ../../scripts/pass-seed-apprise.sh via `docker exec
# -i apprise python3 /scripts/seed.py`, with the URL piped in over stdin —
# never as a command-line argument.
webhook = sys.stdin.read().strip()
data = urllib.parse.urlencode({"urls": webhook}).encode()
req = urllib.request.Request(
    "http://localhost:8000/add/self-hosted", data=data, method="POST"
)
print(urllib.request.urlopen(req).read().decode())
