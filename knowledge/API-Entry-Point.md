# API Entry Point
#architecture #api #mojolicious

The `sauron-api.pl` script is the gateway to the REST API.

## Key Responsibilities
- **Module Resolution:** Uses `FindBin` to ensure local `Sauron/` and `lib/` modules are loaded.
- **Config Loading:** Reuses `Sauron::Sauron::load_config()` to maintain consistency with the CGI interface.
- **Database Lifecycle:** Establishes the DB connection via `Sauron::DB::db_connect()` at startup.
- **Routing:** Loads the [[REST-API-Structure]] from `openapi.yaml` and mounts it under `/api/v1`.

## Development Usage
Run the API in development mode with auto-reload:
```bash
morbo sauron-api.pl
```

## Related
- [[Tech-Stack]]
- [[Environment-Setup]]
