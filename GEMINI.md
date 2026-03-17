# Sauron REST API Development Mandates

This document serves as the foundational architectural and security guide for the Sauron REST API. All development must strictly adhere to these standards.

## 1. Project Overview
A production-grade REST API for the Sauron DNS/DHCP Management System, built using **Mojolicious** and **Mojolicious::Plugin::OpenAPI**.

## 2. Core Architectural Principles
*   **OpenAPI-First Development:** The `openapi.json` or `openapi.yaml` file is the source of truth. All implementation must be driven by the specification.
*   **API Versioning:** All endpoints must be versioned (e.g., `/api/v1/...`) to ensure backward compatibility as the API expands.
*   **Separation of Concerns:** 
    *   **Controllers:** Handle HTTP logic and request/response mapping.
    *   **Logic Layer:** Interface directly with `Sauron::BackEnd` and `Sauron::Util`.
    *   **Validation:** Delegated to the OpenAPI plugin to ensure strict schema compliance.
*   **Statelessness:** The API must remain stateless to facilitate scaling and production deployment.

## 3. Security Mandates (Priority 1)
*   **Authentication:** 
    *   Implement database-backed API key authentication.
    *   Keys must be manageable via the Sauron CGI (User self-service).
    *   Integrate with Sauron's existing user/password database logic found in `Sauron::BackEnd`.
*   **Authorization:**
    *   Map API requests to Sauron's internal privilege levels (`ALEVEL_*`) based on the user identified by the API key.
    *   Enforce "Least Privilege" access control.
*   **Input Sanitization:** 
    *   Rely on OpenAPI schema validation for type checking.
    *   Further sanitize inputs before passing them to `Sauron::BackEnd` to prevent SQL injection or command injection.
*   **Error Handling:** 
    *   Never leak stack traces or internal database errors to the client.
    *   Use standardized RFC 7807 (Problem Details for HTTP APIs) or consistent JSON error structures.
*   **TLS/SSL:** Production deployment must be strictly HTTPS.

## 4. Extensibility & Future-Proofing
*   **Modular Controllers:** Organize controllers by Sauron domain (e.g., `ZoneController`, `HostController`, `UserController`).
*   **Pluggable Auth:** Design the authentication layer to be swapped or extended (e.g., adding LDAP/OIDC support later).
*   **Sauron Core Integration:** Always prefer utilizing existing functions in `Sauron/*.pm` over rewriting database queries to maintain consistency with the CGI interface.

## 5. Development Workflow
1.  **Define:** Update the OpenAPI specification for new endpoints.
2.  **Mock:** Use Mojolicious to serve mock responses for frontend/client testing.
3.  **Implement:** Code the controller and bridge it to the Sauron backend.
4.  **Validate:** Run automated tests against the OpenAPI schema.

## 6. Environment & Paths
*   **Source:** `~/sauron`
*   **API Root:** `~/sauron/sauron_api`
*   **Config:** `/usr/local/etc/sauron/config`
*   **Legacy Libraries:** Add `~/sauron` to `@INC` inside the Mojolicious app.

## 7. Knowledge Management (Zettelkasten)
*   **Atomic Notes:** Create and maintain atomic, inter-linked notes in the `/knowledge` directory.
*   **Knowledge Graph:** Use `[[note-title]]` syntax for cross-referencing.
*   **Continuous Updates:** As new patterns or logic are discovered in the Sauron core, document them immediately as Zettelkasten notes.
