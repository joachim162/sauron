# Running the API
#setup #dev-env #mojolicious

There are two primary ways to run the Sauron REST API during development.

## 1. Development Mode (Morbo)
The preferred method for active coding.
- **Command:** `morbo script/sauron_api`
- **Benefit:** Automatically detects file changes and restarts the server.
- **Default Port:** 3000

## 2. Standard Daemon
Useful for stable testing.
- **Command:** `perl script/sauron_api daemon`
- **Default Port:** 3000

## Environment Requirements
Before running either command, ensure the [[Legacy-Pathing-Issues]] are addressed by setting the library path:
```bash
export PERL5LIB=$HOME/sauron
```

## Production (Hypnotoad)
(For future reference) Production deployments should use `hypnotoad`:
- **Command:** `hypnotoad script/sauron_api`
- **Benefit:** Full-featured, non-blocking web server with zero-downtime restarts.

## Related
- [[API-Entry-Point]]
- [[Environment-Setup]]
- [[Swagger-UI-Access]]
