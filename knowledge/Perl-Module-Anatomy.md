# Perl Module Anatomy
#perl #architecture #conventions

Every Perl module (`.pm`) must follow a specific structure to be correctly loaded by the framework.

## The True Return Value
Mandate: The last line of every `.pm` file must be a true value, typically `1;`.
- **Reason:** Perl's `require` and `use` statements verify the initialization of the module by checking its return value.
- **Failure:** If missing, Perl throws a "did not return a true value" compilation error.

## Namespace Declaration
The first line must declare the package matching the file path:
```perl
package SauronAPI::Controller::Zone;
```

## Import Mandates
For the Sauron REST API, always use the explicit import pattern to avoid [[Namespace-Management]] collisions:
```perl
use Sauron::BackEnd (); # Parens prevent function pollution
```

## Related
- [[Namespace-Management]]
- [[Controller-Role]]
