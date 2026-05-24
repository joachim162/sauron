# Host Masks
#permissions #authorization #hosts #masks #regex

Host masks are `user_rights` entries that restrict which hosts a user can create, modify, or delete by matching against regex patterns. They are loaded by `Sauron/BackEnd::get_permissions()` (`BackEnd.pm:4011`).

## Permission Types

| rtype | Name | Rule Format | Stored In |
|-------|------|-------------|-----------|
| 4 | Hostname mask | regex | `$perms{hostname} = [[zoneid, regex], …]` |
| 9 | Template mask | regex | `$perms{tmplmask} = [regex, …]` |
| 10 | Group mask | regex | `$perms{grpmask} = [regex, …]` |
| 11 | Delete mask | regex | `$perms{delmask} = [[zoneid, regex], …]` |

### Hostname Mask (rtype=4)

Restricts a user to only create or edit hosts whose domain name matches a regex. The `rref` stores the zone ID, and `rule` stores the regex.

```sql
rtype = 4, rref = zone_id, rule = '^admin-.*'
```

Enforced in `Sauron/CGI/Hosts.pm:1298`:
```perl
if (check_perms('host',$host{domain},1)) {
    alert2("Invalid hostname: does not conform to your restrictions");
}
```

### Delete Mask (rtype=11)

Restricts which hosts a user is allowed to delete. Same format as hostname mask (zone ID + regex). Only hosts whose domain matches the regex can be deleted.

### Template Mask (rtype=9)

Restricts which MX/WKS template names a user can see or select. `rule` is a regex that template names must match.

### Group Mask (rtype=10)

Restricts which group names a user can see or assign. `rule` is a regex that group names must match.

## Enforcement

Hostname and delete masks are enforced in `Sauron/CGI/Hosts.pm` during host add/edit and delete operations. Template and group masks filter the available options in dropdown lists rather than blocking the operation directly.

## Related

- [[Required-Host-Fields]] — mandatory/optional field configuration
- [[Sauron-Core-Authorization-System]] — full permission type reference
