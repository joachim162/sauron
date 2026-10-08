# API Helpers
#api #mojolicious #helpers #refactoring

Mojolicious helpers are used to centralize common logic across controllers, such as resource retrieval and standardized error reporting.

## server_id Retrieval
The `get_server_id_or_404` helper fetches a Sauron `server_id` by name and raises a `SauronAPI::Exception` (404 Not Found) if the server does not exist.

### Definition
Registered in `SauronAPI.pm`:
```perl
$self->helper(get_server_id_or_404 => sub ($c, $name) {
  my $id = Sauron::BackEnd::get_server_id($name);
  return $id if $id > 0;

  SauronAPI::Exception->not_found("Server '$name' not found");
});
```

A global `around_dispatch` hook catches any `SauronAPI::Exception` that unwinds out of a helper or controller action and renders it through the shared `render_exception` helper.

### Usage
In any controller:
```perl
my $server_id = $self->get_server_id_or_404($name) or return;
```
On success the ID is returned. On failure the helper throws and the global handler renders the 404, so the `or return` is only a defensive fallback (the failure path never returns).

## Benefits
- **Consistency:** Ensures all "Server Not Found" errors use the same JSON structure and status code.
- **DRY:** Removes repetitive lookup and error-checking blocks from multiple controllers (e.g., `Server.pm`, `Zone.pm`).

## Related
- [[Controller-Role]]
- [[Sauron-Core-Integration]]
- [[API-Entry-Point]]
