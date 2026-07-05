# Wraps the official kopia/kopia image with a small bootstrap entrypoint —
# that image's own ENTRYPOINT is just the bare `kopia` binary (confirmed
# from kopia/kopia's own tools/docker/Dockerfile), so there's no built-in
# logic to connect/create the B2 repository or generate a TLS cert before
# starting the server. entrypoint.sh does that once, then execs the real
# server process.
FROM kopia/kopia:0.23.1@sha256:89fd95ee2942880ca00eae964266958a394421ddbdf69bca62e38afc55f5900e
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
