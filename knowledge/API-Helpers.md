# API Helpers
#api #mojolicious #helpers #refactoring

Mojolicious helpers are used to centralize common logic across controllers, such as resource retrieval and standardized error reporting.

## server_id Retrieval
The `get_server_id_or_404` helper is used to fetch a Sauron `server_id` by name and automatically render a 404 response if the server does not exist.

### Definition
Registered in `SauronAPI.pm`:
```perl
$self->helper(get_server_id_or_404 => sub ($c, $name) {
  my $id = Sauron::BackEnd::get_server_id($name);
  return $id if $id > 0;

  $c->render(
    openapi => {
      error   => 'Not Found',
      message => "Server '$name' not found"
    },
    status  => 404
  );
  return undef;
});
```

### Usage
In any controller:
```perl
my $server_id = $self->get_server_id_or_404($name) or return;
```
Note: The `or return` is essential to stop the execution of the controller action after the helper has rendered the error response.

## Benefits
- **Consistency:** Ensures all "Server Not Found" errors use the same JSON structure and status code.
- **DRY:** Removes repetitive lookup and error-checking blocks from multiple controllers (e.g., `Server.pm`, `Zone.pm`).

## Related
- [[Controller-Role]]
- [[Sauron-Core-Integration]]
- [[API-Entry-Point]]
