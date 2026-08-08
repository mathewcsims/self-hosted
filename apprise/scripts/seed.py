import sys
import urllib.parse
import urllib.request

# Reads one "<config key>\t<comma-separated Apprise URLs>" line from stdin and
# registers those URLs under that config key, so anything on the LAN can POST
# to /notify/<key> without knowing the underlying webhook or token. Invoked
# once per key from ../../scripts/pass-seed-apprise.sh via `docker exec -i
# apprise python3 /scripts/seed.py`, with the line piped in over stdin — never
# as a command-line argument, since the URLs embed secrets.
#
# Two keys are seeded today:
#   self-hosted — Discord + ntfy topic "alerts". The general firehose every
#                 notifier in the repo posts to.
#   fail2ban    — ntfy topic "fail2ban" at priority=low, and NOTHING else.
#                 Ban/unban events fire dozens of times a day off the
#                 caddy-abuse jail, which drowned out everything else on the
#                 shared key; they get their own quiet topic instead.
line = sys.stdin.read().strip()
key, _, urls = line.partition("\t")
if not key or not urls:
    sys.exit("Expected '<config key>\\t<urls>' on stdin")

data = urllib.parse.urlencode({"urls": urls}).encode()
req = urllib.request.Request(
    f"http://localhost:8000/add/{key}", data=data, method="POST"
)
print(f"{key}: {urllib.request.urlopen(req).read().decode()}")
