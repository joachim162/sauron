#import "defs.typ": note, warn

#set heading(numbering: "A.1", supplement: [Appendix])
#counter(heading).update(0)

= BackEnd Function Reference

The public surface of `Sauron::BackEnd`, grouped by domain. Signatures
follow the source's prototype conventions; `\%rec` means a hash reference
filled or consumed, return `0` means success unless noted.

#table(
  columns: (auto, 1fr),
  table.header([Domain], [Functions]),
  [Infrastructure], [`set_muser(user)` · `sauron_db_version()` /
    `get_db_version()` · `fix_bools` · `new_sid()` · `cgi_disabled()` ·
    `write2log(msg)`],
  [Generic record layer], [`get_record` · `add_record(table,\%rec)→id` ·
    `add_record_sql` · `update_record(table,\%rec)` · `copy_records` ·
    `add_std_fields` / `del_std_fields` · `get_field` / `update_field` ·
    `update_textarea_field`],
  [Array fields], [`get_array_field(table,count,fields,header,where,\%rec,key)`
    · `add_array_field(table,fields,key,\%rec,rfields,vals)` ·
    `update_array_field(table,count,fields,key,\%rec,vals)` ·
    `get_aml_field` / `update_aml_field`],
  [Servers], [`get_server_id(name)→id` · `get_server_list` ·
    `get_server(id,\%rec)` · `add_server` · `update_server` ·
    `delete_server`],
  [Zones], [`get_zone_id(name,serverid)` · `get_zone_id_by_name` ·
    `get_zone_list(serverid,rev,dummy[,noexp])` · `get_zone_list2` ·
    `get_zone(id,\%rec)` · `add_zone` · `update_zone` · `delete_zone` ·
    `copy_zone(srcserver,srczone,dstserver,dstzone)`],
  [Hosts], [`get_host_id(zoneid,domain)` · `get_host_id_by_fqdn(fqdn)` ·
    `get_host(id,\%rec)` · `add_host` · `update_host` · `delete_host` ·
    `get_host_types()` · `ip_in_use(serverid,ip)` ·
    `domain_in_use(zoneid,domain)` · `hostname_in_use(zoneid,fqdn)` ·
    `get_host_network_settings(serverid,ip,\%rec)`],
  [IP assignment], [`get_free_ip_by_net(serverid,cidr,mac,oldip,policy)`
    · `get_net_ip_policy(serverid,cidr)` · `ip_policy_names(cidr)` ·
    `get_ip_sugg(hostid,serverid,\%perms)` · (dead: `auto_address`,
    `next_free_ip`)],
  [Nets & VLANs], [`get_net_by_cidr` · `get_net_cidr_by_ip` ·
    `get_net_list(serverid,alevel,\%perms[,mode])` · `get_net` ·
    `add_net` · `update_net` · `delete_net` · `get_vlan*` (id, name,
    vlanno, list, CRUD)],
  [Host groups], [`get_group_by_name` · `get_group_type_by_name` ·
    `get_group(id,\%rec)` · `add_group` · `update_group` ·
    `delete_group` · `get_group_list`],
  [Templates], [`get/add/update/delete_mx_template` +
    `get_mx_template_by_name` + `get_mx_template_list` · same families
    for `wks_template`, `printer_class`, `hinfo_template`],
  [Users & groups], [`get_user(name,\%rec)` · `get_user_by_email` ·
    `get_user_by_id` · `add_user` · `update_user` · `delete_user` ·
    `get_all_users` · `get_user_status(uid)` · `get_user_group*` ·
    `delete_user_group`],
  [Permissions], [`get_permissions(uid,\%perms)`],
  [Keys & ACLs], [`get_key(_by_name/_list)` · `add/update/delete_key` ·
    `get_acl(_by_name/_list)` · `add/update/delete_acl`],
  [VMPS], [`get_vmps(_by_name/_list)` · `add/update/delete_vmps`],
  [News / who], [`add_news` · `get_news_list` · `get_who_list`],
  [Audit & sessions], [`update_history(uid,sid,type,action,info,ref)` ·
    `get_history_host` · `get_history_session` ·
    `update_lastlog(uid,sid,state,ip,host)` · `get_lastlog` ·
    `fix_utmp(timeout,checkzero)` · `save_state` / `load_state` /
    `remove_state`],
  [API tokens], [`generate_pat_token` · `create_pat(uid,name,expiry)` ·
    `verify_pat(token)→uid` · `revoke_pat` · `get_pats` ·
    `update_pat_last_used`],
  [Frontend sessions], [`generate_session_token` ·
    `create_session(uid,ip,agent,ttl)` · `verify_session(token)` ·
    `delete_session` · `delete_user_sessions` ·
    `cleanup_expired_sessions`],
)

= Quick Reference Tables

== Host types

#table(
  columns: (auto, auto, auto),
  table.header([Type], [Name], [Notes]),
  [0], [Misc], [reserved],
  [1], [Host], [full record set + DHCP],
  [2], [Delegation], [NS + DS to child zone],
  [3], [Plain MX], [mail-only name],
  [4], [Alias (CNAME)], [`alias` / `cname_txt`],
  [5], [Printer], [printcap entries],
  [6], [Glue record], [address for in-child NS],
  [7], [Alias (A rec)], [extra A records via `arec_entries`],
  [8], [SRV entry], [SRV only],
  [9], [DHCP only], [MAC reservation, no DNS],
  [10], [Zone apex], [internal, one per master zone],
  [11], [SSHFP entry], [SSHFP only],
  [12], [TLSA entry], [TLSA only],
  [13], [TXT entry], [TXT only],
  [101], [Host reservation], [DHCPv6 DUID/IAID pre-registration],
)

== `user_rights.rtype`

#table(
  columns: (auto, auto, auto),
  table.header([rtype], [Right], [rule]),
  [0], [group membership], [—],
  [1], [server], [R / RW / RWS],
  [2], [zone], [R / RW / RWS],
  [3], [net range], [IP range],
  [4], [hostname mask], [regex (rref = zone)],
  [5], [IP mask], [regex],
  [6], [authorization level], [0--999, max wins],
  [7], [expiration limit], [days],
  [8], [default dept], [text],
  [9], [template mask], [regex],
  [10], [group mask], [regex],
  [11], [delete mask], [regex (rref = zone)],
  [12], [required host field], [field name (rref 0 = required)],
  [13], [privilege flags], [AREC, CNAME, SCNAME, MX, SRV, DELEG, GLUE,
    DHCP, PRINTER, TLSA, TXT, RESERV, …],
  [14], [default host], [text],
)

== History / lastlog / zone types

#table(
  columns: (1fr, 1fr, 1fr),
  table.header([`history.type`], [`lastlog.state`], [`zones.type`]),
  [1 host \ 2 zone \ 3 server \ 4 net \ 5 user \ 6 user group],
  [1 login \ 2 logout \ 3 idle timeout \ 4 reconnect],
  [M master \ S slave \ F forward \ H hint],
)

= Glossary

/ ALEVEL: Numeric authorization level (0--999) gating functional areas;
  a user's effective level is the max over direct and group grants.
/ AML: Address match list — BIND ACL expression (CIDRs, named ACLs, TSIG
  keys, negations); stored in `cidr_entries` with `count = 7`.
/ Apex: The zone's own name (`@`); in Sauron a hidden host of type 10.
/ AXFR / IXFR: Full / incremental zone transfer between master and
  slave.
/ Delegation: NS records in a parent zone handing a subtree to a child
  zone; Sauron host type 2.
/ DORA: The DHCPv4 Discover–Offer–Request–Ack exchange.
/ DUID / IAID: DHCPv6 client identity (per machine / per interface);
  columns on `hosts`.
/ Dummy net/zone: Organizational rows excluded from generation; dummy
  nets group hosts inside a real subnet.
/ Glue record: Address record for a nameserver living inside the zone it
  serves; Sauron host type 6.
/ Marker row: BackEnd's array-field wire format:
  `[id, cols…, marker]` with marker −1 delete / 1 update / 2 insert.
/ Pending: Zone state where data changed after the last serial bump —
  edits not yet visible in DNS.
/ PAT: Personal Access Token, `sau_sk_…` bearer credential for the REST
  API.
/ RHF: Required Host Fields — per-site and per-user mandatory/optional
  policy for host metadata fields.
/ RWS: Read-write-super object right; unlocks operations plain RW
  cannot (e.g. some deletes/overrides).
/ Satellite table: Small table holding one-to-many child rows with
  polymorphic `(type, ref)` parent references.
/ Serial: Zone version number (`YYYYMMDDnn`); slaves transfer only on
  increase.
/ Shared network: dhcpd construct for multiple IP subnets on one wire;
  generated from Sauron VLANs.
/ SOA: Start of Authority record — zone header carrying serial and
  timers.
/ TSIG: Shared-secret HMAC authentication for DNS messages (transfers,
  updates); `keys` table.
/ utmp: Table of live legacy-CGI sessions keyed by cookie.
