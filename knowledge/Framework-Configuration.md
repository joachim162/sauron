# Framework Configuration
#mojolicious #config #security

The `sauron_a_p_i.yml` file stores settings specific to the Mojolicious web framework.

## Primary Roles
1. **Secrets:** Stores the entropy used for signing cookies and session data. This is critical for preventing session hijacking.
2. **Environment Overrides:** Can store settings that change between development, staging, and production (e.g., logging levels).
3. **API Logic Settings:** Stores parameters like token expiration times or CORS policies.

## Distinction from Legacy Config
- **Legacy Config (`/etc/sauron/config`):** Database credentials, DNS/DHCP generation paths, and core Sauron business rules.
- **Framework Config (`sauron_a_p_i.yml`):** HTTP-level settings, web security, and framework plugins.

## Production Best Practice
- Never commit real production secrets to version control.
- Use environment variables or restricted-access YAML files for production secrets.

## Related
- [[API-Entry-Point]]
- [[Environment-Setup]]
