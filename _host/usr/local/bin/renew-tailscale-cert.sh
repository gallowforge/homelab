#!/bin/bash
# Renew the tailnet TLS cert that Caddy serves on :8443-8453, then make Caddy load it.
# Run weekly by tailscale-cert-renew.timer. Log: journalctl -u tailscale-cert-renew
#
# --force matters: the Caddyfile loads the cert files statically (tls <crt> <key>),
# so the config text never changes on renewal. Without --force `caddy reload` sees
# an identical config, does nothing, and Caddy keeps serving the old cert until it
# expires. (caddy.go: `if !forceReload && bytes.Equal(...)` -> "config is unchanged")
set -euo pipefail
DOMAIN="raspberrypi.example-tailnet.ts.net"
CERT_DIR="/etc/tailscale-certs"
tailscale cert --cert-file "$CERT_DIR/$DOMAIN.crt" --key-file "$CERT_DIR/$DOMAIN.key" "$DOMAIN"
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --force
