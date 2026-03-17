# Swagger UI Access
#api #swagger #mojolicious #documentation

The Sauron REST API uses an interactive Swagger UI to provide live documentation and a testing interface for the endpoints defined in the [[OpenAPI-Core-Concepts]].

## Configuration
Access is enabled via the `Mojolicious::Plugin::SwaggerUI` plugin in the [[API-Entry-Point]]. This is separate from the base `OpenAPI` plugin to ensure the UI is served reliably at its own endpoint.

```perl
$self->plugin(SwaggerUI => {
  route => $self->routes()->any('api'),
  url   => "/api/v1",
  title => "Sauron API Documentation"
});
```

## How to Access
- **URL:** `/api`
- **Spec Source:** The UI fetches the specification from `/api/v1`, which is the JSON representation served by the OpenAPI plugin.

## Requirements
- `Mojolicious::Plugin::SwaggerUI` must be installed in the Perl environment.

## Troubleshooting
If the UI displays "Page Not Found" or fails to load the specification:
1. Ensure the `url` in the SwaggerUI plugin correctly points to the route where the OpenAPI plugin is mounted.
2. Verify that the OpenAPI specification is valid according to [[Offline-API-Validation]].

## Related
- [[API-Entry-Point]]
- [[OpenAPI-Core-Concepts]]
- [[REST-API-Structure]]
