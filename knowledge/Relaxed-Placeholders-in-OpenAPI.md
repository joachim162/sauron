# Relaxed Placeholders in OpenAPI
#mojolicious #openapi #routing #dns

DNS-related APIs often require path parameters that contain dots (e.g., zone names or hostnames).

## The Mojolicious Default
Standard Mojolicious route placeholders (e.g., `:zone`) match all characters **except** `/` and `.`.
- **Impact:** A request to `/zones/example.com` will fail with a 404 if using a standard placeholder.

## The Solution: `x-mojo-placeholder`
In the `openapi.yaml` specification, use the Mojolicious extension to define a relaxed placeholder:
```yaml
parameters:
  - name: zone
    in: path
    x-mojo-placeholder: '#' # Equivalent to Mojolicious '#' (relaxed) placeholder
    schema:
      type: string
```

## Placeholder Types
- `:` (Default): Everything except `/` and `.`
- `#` (Relaxed): Everything except `/` (Ideal for DNS names)
- `*` (Wildcard): Everything including `/`

## Related
- [[Mojolicious-OpenAPI-Extensions]]
- [[API-Entry-Point]]
- [[Namespace-Management]]
