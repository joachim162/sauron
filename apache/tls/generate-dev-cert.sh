#!/bin/bash
# Generate self-signed development TLS certificate for Apache
# WARNING: This is for local development only. Do NOT use in production.

set -e

CERT_DIR="$(dirname "$0")"

if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    echo "TLS certificates already exist in $CERT_DIR"
    exit 0
fi

echo "Generating self-signed TLS certificate for development..."
openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"

echo "TLS certificate generated successfully."
echo "  Key: $CERT_DIR/server.key"
echo "  Cert: $CERT_DIR/server.crt"
