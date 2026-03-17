# The Self Invocant
#mojolicious #perl #mvc

In Mojolicious controllers, `$self` is the object representing the current HTTP request/response cycle.

## Core Responsibilities of `$self`
1. **Context:** Holds the `Mojo::Message::Request` and `Mojo::Message::Response` objects.
2. **Interface:** Provides the `render()` method to finalize the transaction.
3. **Bridge:** Connects the controller to the main application via `$self->app`.
4. **OpenAPI Helper:** When using `Mojolicious::Plugin::OpenAPI`, `$self` gains methods to access validated data and schema definitions.

## Modern Perl Syntax
We use the `-signatures` feature, which allows us to define it in the subroutine header:
```perl
sub my_action ($self) { ... }
```
This is a cleaner version of the older Perl style: `sub my_action { my $self = shift; ... }`.

## Related
- [[Controller-Role]]
- [[OpenAPI-Core-Concepts]]
