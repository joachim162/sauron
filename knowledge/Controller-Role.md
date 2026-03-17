# Controller Role
#architecture #mojolicious #mvc

In the Sauron REST API, Controllers are the coordination layer between the HTTP interface and the legacy Perl backend.

## Key Responsibilities
1.  **Orchestration:** Mapping incoming requests to specific [[Sauron-Core-Integration]] functions.
2.  **Validation Feedback:** While OpenAPI handles schema validation, Controllers handle business-level validation (e.g., "does this server ID actually belong to this user?").
3.  **Data Transformation:** Converting legacy Perl data structures (often complex nested hashes/arrays) into the clean JSON format defined in [[OpenAPI-Core-Concepts]].
4.  **HTTP Semantic Mapping:** Translating Sauron error codes (integers like -1, -2) into appropriate HTTP status codes (404, 403, 500).

## The "Thin Controller" Rule
Mandate: Keep controllers thin. They should be "Glue Code."
- Complexity belongs in the [[Sauron-Core-Integration]] layer or dedicated Models.
- SQL must **never** appear in a Controller.

## Related
- [[REST-API-Structure]]
- [[Architecture-Overview]]
- [[API-Helpers]]
