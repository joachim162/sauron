# Mojolicious OpenAPI Extensions
#api #mojolicious #openapi #routing

Mojolicious supports several custom extensions in the OpenAPI spec (prefixed with `x-mojo-`).

## Key Extensions
- **`x-mojo-to`**: Explicitly defines the controller and action. 
  - Format: `"Controller#action"`
  - Use Case: When the [[OpenAPI-Core-Concepts]] `operationId` mapping is insufficient or ambiguous.
- **`x-mojo-name`**: Assigns a name to the route for internal use within the framework.

## Convention over Configuration
By default, the `Mojolicious::Plugin::OpenAPI` uses the `operationId` to infer the route:
1. It looks for a controller based on the tags or path.
2. It looks for a subroutine matching the `operationId`.

## Recommendation for Sauron API
- **Avoid** using these extensions unless absolutely necessary.
- Keeping them out ensures the `openapi.yaml` remains a generic, cross-platform source of truth.
- Rely on consistent `operationId` naming to drive routing.

## Related
- [[Controller-Role]]
- [[API-Entry-Point]]
