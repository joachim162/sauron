# Required Host Fields (RHF)
#permissions #authorization #hosts #rhf #configuration

The Required Host Fields (RHF) system lets administrators control which informational fields on a host record are mandatory or optional for each user. It's a per-user override of the system-wide defaults defined in `%SAURON_RHF`.

## Default Configuration

Defined in `Sauron/Sauron.pm:90-100`, overridable in `config.in:145-155`:

| Field | Default | Label |
|-------|---------|-------|
| `huser` | 0 (required) | User |
| `dept` | 0 (required) | Dept. |
| `location` | 0 (required) | Location |
| `ether` | 0 (required) | MAC Address |
| `duid` | 0 (required) | DUID |
| `asset_id` | 1 (optional) | Asset ID |
| `model` | 1 (optional) | Model |
| `serial` | 1 (optional) | Serial no. |
| `misc` | 1 (optional) | Misc. |
| `email` | 1 (optional) | User Email |
| `info` | 1 (optional) | [Extra] Info |

0 = mandatory (must be non-empty), 1 = optional (may be empty).

## Per-User Override via `user_rights`

Administrators add entries in `user_rights` with `rtype=12` (reqhostfield):

- `rule` = field name (e.g. `"dept"`, `"location"`, `"asset_id"`)
- `rref` = 0 (required) or non-zero/1 (optional)

Schema: `sql/user_rights.sql:29`

```sql
rtype = 12 => reqhostfield
rref  = 0  => Required, non-zero => Optional
rule  = field name (huser, dept, location, ...)
```

## Load and Merge

During login, `cgi/sauron.cgi:301-303` merges per-user RHF overrides into the global `%SAURON_RHF`:

```perl
foreach $rhf_key (keys %{$perms{rhf}}) {
    $SAURON_RHF{$rhf_key}=$perms{rhf}->{$rhf_key};
}
```

Permission loading: `Sauron/BackEnd.pm:4074`
```perl
elsif ($type == 12) { $rec->{rhf}->{$mode}=$ref; }
```

Merged into `$perms{rhf}->{fieldname}` — see [[Sauron-Core-Authorization-System]].

## Form Field Application

In `Sauron/CGI/Hosts.pm`, each editable host field uses `empty=>$main::SAURON_RHF{fieldname}` to set the `empty` attribute. When `empty=0`, `form_check_field` in `CGIutil.pm:180` rejects an empty value:

```perl
unless ($empty == 1) {
    # field is mandatory — empty value triggers error
```

## Host Fields Affected

The fields that can be toggled between required and optional are listed in `Sauron/Sauron.pm:90-100`:
- `huser` — User
- `dept` — Department
- `location` — Location
- `info` — Extra Info
- `ether` — MAC Address
- `duid` — DUID
- `asset_id` — Asset ID
- `model` — Model
- `serial` — Serial number
- `misc` — Miscellaneous
- `email` — User Email

## Display

The user's RHF settings are displayed in the user info page (`Sauron/CGI/Login.pm:198-203`) as "ReqHostField" entries showing the field name and "Required"/"Optional" status.

## Related

- [[Sauron-Core-Authorization-System]] — full permission type reference
- [[Host-Masks]] — hostname, delete, template, and group masks
