#!/bin/bash
set -e

# Generate Apache config from template with actual values
generate_config() {
    local oidc_issuer="${OIDC_ISSUER:-}"
    local oidc_client_id="${OIDC_CLIENT_ID:-}"
    local oidc_client_secret="${OIDC_CLIENT_SECRET:-}"
    local oidc_crypto_passphrase="${OIDC_CRYPTO_PASSPHRASE:-changeme}"

    if [[ -z "$oidc_issuer" ]] || [[ -z "$oidc_client_id" ]] || [[ -z "$oidc_client_secret" ]]; then
        echo "ERROR: OIDC_ISSUER, OIDC_CLIENT_ID, and OIDC_CLIENT_SECRET must be set"
        exit 1
    fi

    # Build the OIDC configuration file
    cat > /usr/local/apache2/conf/extra/httpd-oidc.conf << 'APACHE_EOF'
# Apache OIDC Reverse Proxy Configuration for Sauron API
# Generated from environment variables at startup

# SSL Configuration
SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
SSLCipherSuite HIGH:!aNULL:!MD5
SSLCertificateFile /etc/apache2/tls/server.crt
SSLCertificateKeyFile /etc/apache2/tls/server.key

# OIDC Configuration
OIDCProviderMetadataURL OIDC_ISSUER_PLACEHOLDER/.well-known/openid-configuration
OIDCClientID OIDC_CLIENT_ID_PLACEHOLDER
OIDCClientSecret OIDC_CLIENT_SECRET_PLACEHOLDER
OIDCCryptoPassphrase OIDC_CRYPTO_PASSPHRASE_PLACEHOLDER
OIDCScope "openid profile email"
OIDCRemoteUserClaim email
OIDCDiscoveryTimeout 30
OIDCSessionInactivityTimeout 3600
OIDCSessionMaxDuration 86400
OIDCCacheType session
OIDCSessionType server

APACHE_EOF

    # Replace placeholders with actual values
    sed -i "s|OIDC_ISSUER_PLACEHOLDER|${oidc_issuer}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf
    sed -i "s|OIDC_CLIENT_ID_PLACEHOLDER|${oidc_client_id}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf
    sed -i "s|OIDC_CLIENT_SECRET_PLACEHOLDER|${oidc_client_secret}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf
    sed -i "s|OIDC_CRYPTO_PASSPHRASE_PLACEHOLDER|${oidc_crypto_passphrase}|g" /usr/local/apache2/conf/extra/httpd-oidc.conf

    # Now add the VirtualHost configuration
    cat >> /usr/local/apache2/conf/extra/httpd-oidc.conf << 'VHOST_EOF'

<VirtualHost *:80>
    ServerName localhost
    Redirect permanent / https://localhost/
</VirtualHost>

<VirtualHost *:443>
    ServerName localhost
    DocumentRoot /var/www/html

    SSLEngine on

    # Enable headers for proxying
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "443"

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
    # Protected auth paths - require OIDC authentication
    # =====================================================================

    <Location /auth/proxy-login>
        AuthType openid-connect
        Require valid-user

        RequestHeader unset X-Remote-User
        RequestHeader set X-Remote-User "%{OIDC_CLAIM_EMAIL}e"

        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/auth/proxy-login
        ProxyPassReverse http://sauron_api:3000/auth/proxy-login
    </Location>

    <Location /auth/me>
        AuthType openid-connect
        Require valid-user

        RequestHeader unset X-Remote-User
        RequestHeader set X-Remote-User "%{OIDC_CLAIM_EMAIL}e"

        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/auth/me
        ProxyPassReverse http://sauron_api:3000/auth/me
    </Location>

    # =====================================================================
    # Public auth paths - no OIDC required (API handles its own auth)
    # =====================================================================

    <Location /auth/login>
        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/auth/login
        ProxyPassReverse http://sauron_api:3000/auth/login
    </Location>

    <Location /auth/logout>
        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/auth/logout
        ProxyPassReverse http://sauron_api:3000/auth/logout
    </Location>

    # =====================================================================
    # Root path - serve static frontend or redirect to login
    # =====================================================================

    <Location />
        ProxyPreserveHost On
        ProxyPass http://sauron_api:3000/
        ProxyPassReverse http://sauron_api:3000/
    </Location>

    ErrorLog /proc/self/fd/2
    CustomLog /proc/self/fd/1 common
</VirtualHost>
VHOST_EOF

    echo "Apache config generated successfully"
}

generate_config

echo "Starting Apache..."
exec httpd -DFOREGROUND
