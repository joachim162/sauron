# Architecture Overview
#architecture #overview

The Sauron REST API is a modern layer built on top of a legacy Perl DNS/DHCP management system.

## Key Components
- **Framework:** [[Tech-Stack]] (Mojolicious + OpenAPI)
- **Legacy Core:** [[Sauron-Core-Integration]] (`Sauron::BackEnd`)
- **Security:** [[Security-Protocols]]

## Design Philosophy
- **OpenAPI-First:** Specification drives the implementation.
- **Atomic Logic:** Reuse existing Sauron logic to maintain data integrity.
- **Extensible:** Modular controller design for future expansion.
