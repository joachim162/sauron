# Environment Setup
#setup #dev-env #perl

To develop effectively without root-only access to `/usr/local/sauron`, a "Symlink Trick" is used.

## Configuration
- **PERL5LIB:** Must include `~/sauron` to find local modules.
- **DB Symlink:** `~/sauron/Sauron/DB.pm` should be a symlink to `DB-DBI.pm`.
- **System Link:** `/usr/local/sauron` linked to `~/sauron`.

## Database Connection
- Use `host=localhost` in `$DB_DSN` to force password authentication (bypassing peer authentication issues).
- See: [[Architecture-Overview]]
