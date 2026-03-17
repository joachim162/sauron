# REST API Structure
#architecture #api #setup

The REST API is organized to separate the HTTP interface from the core Sauron logic.

## Directory Layout (Full App)
- `sauron_api/script/sauron_api`: The application runner.
- `sauron_api/lib/SauronAPI.pm`: The main startup logic (replaces `sauron-api.pl`).
- `sauron_api/lib/SauronAPI/Controller/`: Contains domain-specific controllers.
- `sauron_api/public/api/openapi.yaml`: The API specification.
- `sauron_api/t/`: Automated test suite.

## Logic Flow
1. **Request:** Client calls an endpoint defined in `openapi.yaml`.
2. **Validation:** `Mojolicious::Plugin::OpenAPI` validates the request.
3. **Controller:** The corresponding method in `lib/Sauron/API/Controller/` is executed.
4. **Backend:** Controller calls `[[Sauron-Core-Integration]]` modules.
5. **Response:** Data is returned as JSON following the OpenAPI schema.

## Related
- [[Tech-Stack]]
- [[Architecture-Overview]]
- [[Swagger-UI-Access]]
