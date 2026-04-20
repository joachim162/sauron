#!/bin/bash
set -e

echo "=== Sauron Docker Startup ==="

cd /srv/sauron

if [ ! -L Sauron/DB.pm ]; then
    ln -sf DB-DBI.pm Sauron/DB.pm
fi

if grep -q '__CONF_FILE_PATH__' Sauron/Sauron.pm 2>/dev/null; then
    echo "=== Patching source tree for bind mount ==="
    ./configure && make install
fi

echo "Waiting for PostgreSQL..."
for i in {1..30}; do
    if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" > /dev/null 2>&1; then
        echo "PostgreSQL is ready."
        break
    fi
    echo "Waiting for PostgreSQL... ($i/30)"
    sleep 2
done

if [ "$i" -eq 30 ]; then
    echo "PostgreSQL failed to start within an acceptable time."
    exit 1
fi

CONFIG_FILE="/usr/local/etc/sauron/config"

echo "=== Updating config ==="
sed -i "s/\(\$DB_DSN\s*=\s*\).*/\1\"dbi:Pg:dbname=$POSTGRES_DB;host=$POSTGRES_HOST\";/" "$CONFIG_FILE"
sed -i "s/\(\$DB_USER\s*=\s*\).*/\1\"$POSTGRES_USER\";/" "$CONFIG_FILE"
sed -i "s/\(\$DB_PASSWORD\s*=\s*\).*/\1\"$POSTGRES_PASSWORD\";/" "$CONFIG_FILE"
echo "Config updated."

export PGPASSWORD="$POSTGRES_PASSWORD"
export PGUSER="$POSTGRES_USER"
export PGDATABASE="$POSTGRES_DB"
export PGHOST="$POSTGRES_HOST"
export PGPORT="$POSTGRES_PORT"

DB_TABLES=$(psql -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
DB_TABLES=$(echo "$DB_TABLES" | tr -d '[:space:]')

if [ "$DB_TABLES" -eq 0 ] || [ -z "$DB_TABLES" ]; then
    echo "=== Database is empty, initializing... ==="

    echo "=== Creating database tables ==="
    echo y | /srv/sauron/createtables

    echo "=== Creating bff_sessions table ==="
    psql -f /srv/sauron/sql/bff_sessions.sql

    echo "=== Downloading root hints ==="
    if [ ! -s /srv/sauron/named.root ]; then
        wget -q -O /srv/sauron/named.root 'ftp://ftp.rs.internic.net/domain/named.root' || true
    fi
    if [ -s /srv/sauron/named.root ]; then
        /srv/sauron/import-roots default /srv/sauron/named.root
        echo "Root hints imported."
    else
        echo "Warning: named.root not available, skipping."
    fi

    echo "=== Creating test server ==="
    /srv/sauron/runsql - << 'EOF'
INSERT INTO servers (name, hostname, hostmaster)
VALUES ('example', 'sauron.example.com', 'hostmaster@example.com.');
INSERT INTO nets (server, net, netname, vlan, subnet)
VALUES (1, INET '10.10.0.0/16', 'testnet', 1, false);
INSERT INTO nets (server, net, netname, vlan, subnet)
VALUES (1, INET '2001:db8::/32', 'testnet6', 1, false);
EOF

    echo "=== Importing test zones ==="
    if [ -f /srv/sauron/test/middle.earth.zone ]; then
        /srv/sauron/import-zone example middle.earth /srv/sauron/test/middle.earth.zone || true
    fi
    if [ -f /srv/sauron/test/10.10.in-addr.arpa.zone ]; then
        /srv/sauron/import-zone example 10.10.in-addr.arpa /srv/sauron/test/10.10.in-addr.arpa.zone || true
    fi

    echo "=== Creating admin user ==="
    ADMIN_PWD_HASH=$(perl -MDigest::MD5 -e '
        my $salt = 1000000;
        my $password = "admin";
        my $ctx = Digest::MD5->new;
        $ctx->add($salt . $password . "\n");
        print "MD5:" . $salt . ":" . $ctx->hexdigest;
    ')
    psql -c "
    INSERT INTO users (username, password, name, email, superuser, gid)
    VALUES ('admin', '${ADMIN_PWD_HASH}', 'Admin User', 'admin@example.com', true, -1)
    ON CONFLICT (username) DO UPDATE SET
        password = EXCLUDED.password,
        name = EXCLUDED.name,
        email = EXCLUDED.email,
        superuser = EXCLUDED.superuser;
    "

    echo ""
    echo "=== Initialization complete ==="
    echo "Admin user created:"
    echo "  username: admin"
    echo "  email: admin@example.com"
    echo "  password: admin"
    echo ""

else
    echo "=== Database already initialized ($DB_TABLES tables), skipping setup ==="
fi

echo "=== Starting Sauron API ==="
exec "$@"
