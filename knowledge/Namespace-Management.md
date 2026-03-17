# Namespace Management
#perl #architecture #bug-prevention

When bridging a legacy procedural backend with a modern OO framework, name collisions are a significant risk.

## The Collision Risk
Sauron's [[Sauron-Core-Integration]] often exports functions with generic names (e.g., `get_server`, `add_host`). If a [[Controller-Role]] method shares the same name, calling the function without a package prefix will cause **infinite recursion**.

## Prevention Strategies
1. **Explicit Naming:** Always use the full package name when calling legacy functions inside a controller method of the same name:
   ```perl
   sub get_server ($self) {
       Sauron::BackEnd::get_server($id, \%data); # Safe
   }
   ```
2. **Selective Importing:** (Optional) Use `require` instead of `use` or specify an empty import list `use Sauron::BackEnd ();` to force explicit namespacing everywhere.
3. **Controller Method Naming:** Use the [[OpenAPI-Core-Concepts]] `operationId` naming convention (`list_servers`, `get_server`) and be aware of overlapping exports.

## Related
- [[Controller-Role]]
- [[Sauron-Core-Integration]]
- [[Dynamic-API-Binding]]
