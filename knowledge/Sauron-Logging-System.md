# Sauron Logging System
#logging #sauron-core #back-end #audit

Sauron uses three separate logging mechanisms in `Sauron::BackEnd.pm`:

## 1. System Log (syslog)

**Function:** `write2log($msg)` (`BackEnd.pm:177`)

```perl
use Sys::Syslog qw(:DEFAULT setlogsock);
Sys::Syslog::setlogsock('unix');

sub write2log {
  my $msg = shift;
  my $filename = File::Basename::basename($0);
  
  Sys::Syslog::openlog($filename, "cons,pid", "debug");
  Sys::Syslog::syslog("info", encode_str("$msg"));
  Sys::Syslog::closelog();
}
```

**Usage:** Only called in `add_record_sql()` (line 636) to log INSERT SQL statements.

## 2. Session Log (lastlog table)

**Function:** `update_lastlog($uid, $sid, $type, $ip, $host)` (`BackEnd.pm:4084`)

| type | Meaning |
|------|---------|
| 1 | Login (INSERT) |
| 2 | Session active (UPDATE) |
| 3 | Logout (UPDATE) |

**Related functions:**
- `fix_utmp($timeout, $check_zero)` - Cleans expired sessions from `utmp`
- `get_lastlog($n, $user, $list)` - Retrieves login history

## 3. Change History (history table)

**Function:** `update_history($uid, $sid, $type, $action, $info, $ref)` (`BackEnd.pm:4107`)

Records all data modifications:

| type | Resource |
|------|----------|
| 1 | Host changes |
| 2 | Zone changes |
| 3 | Server changes |
| 4 | Net changes |
| 5 | User changes |
| 6 | User group changes |

**Query functions:**
- `get_history_host($host, $list)` - History for a specific host
- `get_history_session($sid, $list)` - History for a session

**Note:** `uid=-1, sid=-1` is allowed for CLI/script operations (line 4111-4112).

## 4. State Management (utmp table)

Session state storage for CGI sessions:
- `save_state($id, $rec)` - Saves session state
- `load_state($id, $rec)` - Loads session state
- `remove_state($id)` - Removes session state

## API Integration

The REST API should call `update_history()` after each CRUD operation:

```perl
# Example: Zone creation
update_history($api_user_id, $sid, 2,  # type=2 (zone)
               'create', 'Zone: ' . $zone_name, $zone_id);

# Example: Host update
update_history($api_user_id, $sid, 1,  # type=1 (host)
               'update', 'Host: ' . $host_name, $host_id);
```

For API operations without session tracking, use `sid=-1`.

## Related
- [[Sauron-Core-Authorization-System]] - User authorization model
- [[Database-API-Key-Authentication]] - API authentication
- [[BackEnd.pm]] - Core module location
