#!/bin/bash
set -e

# Generate a simple proxy-only config (no OIDC auth)
generate_proxy_only_config() {
    local server_name="${SERVER_NAME:-localhost}"
    cat > /usr/local/apache2/conf/extra/httpd-oidc.conf << PROXY_EOF
# Apache Proxy-Only Configuration for Sauron API
# No OIDC authentication configured

ServerName ${server_name}

Listen 443

<VirtualHost *:80>
    ServerName ${server_name}
    Redirect permanent / https://${server_name}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${server_name}

    SSLEngine on
    SSLCertificateFile /etc/apache2/tls/server.crt
    SSLCertificateKeyFile /etc/apache2/tls/server.key
    SSLProtocol all -SSLv3
    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder on
    SSLCompression off

    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "443"

    # Frontend static files
    <Location /app>
        ProxyPreserveHost On
        ProxyPass FRONTEND_BACKEND_PLACEHOLDER/app
        ProxyPassReverse FRONTEND_BACKEND_PLACEHOLDER/app
    </Location>

    # API proxy — ProxyPass ! excludes /app/ from catch-all
    ProxyPass /app/ !
    ProxyPass /app !
    ProxyPass / http://sauron_api:3000/
    ProxyPassReverse / http://sauron_api:3000/

    ErrorLog /proc/self/fd/2
    CustomLog /proc/self/fd/1 common
</VirtualHost>
PROXY_EOF

    sed -i "s|FRONTEND_BACKEND_PLACEHOLDER|${FRONTEND_BACKEND:-http://frontend:80}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf
}

# Generate Apache config from template with actual values
generate_config() {
    local oidc_issuer="${OIDC_ISSUER:-}"
    local oidc_client_id="${OIDC_CLIENT_ID:-}"
    local oidc_client_secret="${OIDC_CLIENT_SECRET:-}"
    local oidc_crypto_passphrase="${OIDC_CRYPTO_PASSPHRASE:-changeme}"
    local server_name="${SERVER_NAME:-localhost}"
    local oidc_redirect_uri="${OIDC_REDIRECT_URI:-https://${server_name}/callback}"

    if [[ -z "$oidc_issuer" ]] || [[ -z "$oidc_client_id" ]] || [[ -z "$oidc_client_secret" ]]; then
        echo "WARNING: OIDC environment variables not set. Starting as proxy-only (no OIDC authentication)."
        generate_proxy_only_config
        return
    fi

    # Build the Apache config file
    cat > /usr/local/apache2/conf/extra/httpd-oidc.conf << APACHE_EOF
# Apache OIDC Reverse Proxy Configuration for Sauron API
# Generated from environment variables at startup

ServerName ${server_name}

# Explicitly listen on port 443 for HTTPS
Listen 443

# HTTP to HTTPS redirect
<VirtualHost *:80>
    ServerName ${server_name}
    Redirect permanent / https://${server_name}/
</VirtualHost>

# HTTPS VirtualHost with OIDC authentication
<VirtualHost *:443>
    ServerName ${server_name}

    # SSL Configuration
    SSLEngine on
    SSLCertificateFile /etc/apache2/tls/server.crt
    SSLCertificateKeyFile /etc/apache2/tls/server.key
    SSLProtocol all -SSLv3
    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder on

    # Disable SSL compression to prevent CRIME attacks
    SSLCompression off

    # Tell backend that requests come via HTTPS
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "443"

    # OIDC Configuration
    OIDCProviderMetadataURL OIDC_ISSUER_PLACEHOLDER/.well-known/openid-configuration
    OIDCClientID OIDC_CLIENT_ID_PLACEHOLDER
    OIDCClientSecret OIDC_CLIENT_SECRET_PLACEHOLDER
    OIDCCryptoPassphrase OIDC_CRYPTO_PASSPHRASE_PLACEHOLDER
    OIDCRedirectURI OIDC_REDIRECT_URI_PLACEHOLDER
    OIDCScope "openid profile email"
    OIDCRemoteUserClaim email

    # =====================================================================
    # Protected API paths - require OIDC authentication
    # =====================================================================

    <Location /api/v1>
        AuthType openid-connect
        Require valid-user

        # Strip any client-supplied auth headers to prevent spoofing
        RequestHeader unset X-Remote-User
        # Set the trusted header from the OIDC claims after successful authentication
        RequestHeader set X-Remote-User "%{OIDC_CLAIM_EMAIL}e"

        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/api/v1
        ProxyPassReverse http://sauron_api:3000/api/v1
    </Location>

    # =====================================================================
    # OIDC callback - handled by mod_auth_openidc, must not be proxied
    # =====================================================================

    <Location /callback>
        AuthType openid-connect
        Require valid-user
    </Location>

    # =====================================================================
    # Public auth paths - no OIDC required (API handles its own auth)
    # =====================================================================

    <Location /api/v1/auth/login>
        AuthType None
        Require all granted

        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/api/v1/auth/login
        ProxyPassReverse http://sauron_api:3000/api/v1/auth/login
    </Location>

    <Location /api/v1/auth/logout>
        AuthType None
        Require all granted

        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/api/v1/auth/logout
        ProxyPassReverse http://sauron_api:3000/api/v1/auth/logout
    </Location>

    <Location /api/v1/auth/me>
        AuthType None
        Require all granted

        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/api/v1/auth/me
        ProxyPassReverse http://sauron_api:3000/api/v1/auth/me
    </Location>

    <Location /api/v1/auth/config>
        AuthType None
        Require all granted

        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/api/v1/auth/config
        ProxyPassReverse http://sauron_api:3000/api/v1/auth/config
    </Location>

    # =====================================================================
    # Frontend — served by the frontend service (no OIDC required)
    # =====================================================================

    <Location /app>
        AuthType None
        Require all granted

        ProxyPreserveHost On
        ProxyPass FRONTEND_BACKEND_PLACEHOLDER/app
        ProxyPassReverse FRONTEND_BACKEND_PLACEHOLDER/app
    </Location>

    # Exclude /app/ from API proxy
    ProxyPass /app/ !
    ProxyPass /app !
    ProxyPass / http://sauron_api:3000/
    ProxyPassReverse / http://sauron_api:3000/

    ErrorLog /proc/self/fd/2
    CustomLog /proc/self/fd/1 common
</VirtualHost>
APACHE_EOF

    # Replace placeholders with actual values
    local oidc_issuer_clean="${oidc_issuer%/}"
    sed -i "s|OIDC_ISSUER_PLACEHOLDER|${oidc_issuer_clean}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf
    sed -i "s|OIDC_CLIENT_ID_PLACEHOLDER|${oidc_client_id}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf
    sed -i "s|OIDC_CLIENT_SECRET_PLACEHOLDER|${oidc_client_secret}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf
    sed -i "s|OIDC_CRYPTO_PASSPHRASE_PLACEHOLDER|${oidc_crypto_passphrase}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf
    sed -i "s|OIDC_REDIRECT_URI_PLACEHOLDER|${oidc_redirect_uri}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf
    sed -i "s|FRONTEND_BACKEND_PLACEHOLDER|${FRONTEND_BACKEND:-http://frontend:80}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf

    echo "Apache config generated successfully"
}

if [ ! -f /etc/apache2/tls/server.crt ] || [ ! -f /etc/apache2/tls/server.key ]; then
    echo "=== Generating self-signed TLS certificates ==="
    bash /etc/apache2/tls/generate-dev-cert.sh
fi

generate_config

echo "Starting Apache..."
exec httpd -DFOREGROUND
