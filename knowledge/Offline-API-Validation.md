# Offline API Validation
#api #openapi #troubleshooting #offline

The Perl OpenAPI plugin occasionally fails when trying to fetch the official meta-schema from the internet (e.g., `spec.openapis.org`).

## The Issue
Error: `GET https://spec.openapis.org/...: Not Found`
- Occurs during startup or testing when the validator attempts to verify your `openapi.yaml` against the remote official spec.
- Can cause tests to fail if the network is unavailable or the remote URL structure changes.

## The Fix
Force the use of the **bundled** schema and skip remote validation:
```perl
$self->plugin(OpenAPI => {
  url => ...,
  schema => 'v3',
  skip_validating_specification => 1, # Prevents remote network calls during startup
});
```

## Future Improvement (Long-term Fix)
While skipping validation works for development, a "proper" production fix involves:
1. Downloading the meta-schemas locally.
2. Configuring `JSON::Validator::Store` to map remote URLs to these local files.
3. This ensures specification integrity without requiring internet access.

## Versioning Tip
Use `openapi: 3.0.0` in your YAML for the most stable integration with legacy Perl modules, as specific sub-versions (like `3.0.3`) might trigger more aggressive remote fetching.

## Related
- [[OpenAPI-Core-Concepts]]
- [[API-Entry-Point]]
