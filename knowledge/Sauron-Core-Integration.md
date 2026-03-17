# Sauron Core Integration
#legacy #integration #perl

The REST API must act as a bridge to the existing Sauron logic.

## Key Modules
- **`Sauron::BackEnd`:** Contains core database operations (hosts, zones, users).
- **`Sauron::Util`:** Helper functions for IP manipulation and validation.
- **`Sauron::Sauron`:** Configuration parsing and global settings.

## Rules for Integration
- Always prefer calling `Sauron::BackEnd` functions over writing raw SQL.
- Maintain consistency with the legacy CGI interface's behavior.
