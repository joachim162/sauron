# OpenAPI Core Concepts
#api #openapi #design #mojolicious

The `openapi.yaml` is the source of truth for the Sauron REST API. Understanding these concepts is essential for maintaining the [[Architecture-Overview]].

## 1. OperationId (The Glue)
The `operationId` is the link between the specification and the Perl code.
- **Spec:** `operationId: list_servers`
- **Perl Mapping:** Mojolicious looks for `Sauron::API::Controller::Server::list_servers`.
- **Note:** Always use snake_case for consistency.

## 2. Components & Schemas (The Models)
Schemas define the shape of your data.
- **Validation:** `Mojolicious::Plugin::OpenAPI` uses these to validate both incoming requests and outgoing responses.
- **Reuse:** Define objects once in `components/schemas` and reference them using `$ref: '#/components/schemas/Name'`.
- **Strictness:** The `required` array ensures that the API fails early if essential data is missing from the database result.

## 3. Paths & Methods
- **Versioning:** Handled at the `servers` root (e.g., `/api/v1`).
- **RESTful Verbs:**
    - `GET`: Read data.
    - `POST`: Create data.
    - `PUT`/`PATCH`: Update data.
    - `DELETE`: Remove data.

## 4. Responses & Error Handling
- **Status Codes:** Use standard HTTP codes (200 for OK, 404 for Not Found, 500 for Error).
- **Consistency:** Use a global `Error` schema to ensure all API failures return identical JSON structures.

## 5. Security Schemes
(To be implemented) OpenAPI allows defining [[Security-Protocols]] like JWT or API Keys globally and applying them to specific paths.

## Related
- [[REST-API-Structure]]
- [[API-Entry-Point]]
