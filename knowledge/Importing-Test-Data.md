# Importing Test Data
#setup #testing #data

The `test/` directory contains a canonical "Middle Earth" dataset for development.

## Dataset Contents
- **DNS:** `test/named.conf` and associated `.zone` files.
- **DHCP:** `test/dhcpd.conf` containing subnets and host reservations.

## Import Workflow
Since scripts have hardcoded `-I/opt/sauron` paths, use `perl -I.` to force local module loading.

1. **BIND Import:** 
   `perl -I. ./import --dir=test <servername> test/named.conf`
2. **DHCP Import:** 
   `perl -I. ./import-dhcp --server=<servername> test/dhcpd.conf`

## Benefits for API Dev
- Provides a consistent state for [[Sauron-Core-Integration]] testing.
- Populates [[User-Server-Zone-Hierarchy]] with realistic relationships.
- Enables validation of complex query parameters in the REST API.

## Troubleshooting
- **Missing DB.pm:** Ensure `~/sauron/Sauron/DB.pm` is a symlink to `DB-DBI.pm`.
- **Peer Auth:** Ensure `$DB_DSN` in `config` includes `host=localhost`.
