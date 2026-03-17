# Dynamic API Binding
#api #mojolicious #openapi #workflow

Unlike some frameworks that use static code generation, the Sauron REST API uses dynamic binding.

## How it Works
1. **Source of Truth:** The `openapi.yaml` file defines the contract.
2. **Startup Parsing:** `Mojolicious::Plugin::OpenAPI` parses this file at server start.
3. **Route Injection:** The plugin injects routes into the Mojolicious router based on `x-mojo-to` or `operationId`.
4. **Middleware Validation:** Incoming requests and outgoing responses are validated against the schema in real-time.

## Benefits of Dynamic Binding
- **No Stale Code:** There are no "generated files" that can fall out of sync with the documentation.
- **Immediate Iteration:** Change the YAML, and the API behavior (validation/routing) updates as soon as the server restarts.
- **Clean Controllers:** Controllers stay focused on [[Sauron-Core-Integration]] logic instead of manual input/output validation.

## Related
- [[OpenAPI-Core-Concepts]]
- [[API-Entry-Point]]
- [[Mojolicious-OpenAPI-Extensions]]
