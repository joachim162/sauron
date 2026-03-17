# Legacy Pathing Issues
#legacy #perl #troubleshooting

Many Sauron scripts contain hardcoded Perl include paths (`-I`) in their shebang lines.

## The Issue
Default shebang: `#!/usr/bin/perl -I/opt/sauron`
- `/opt/sauron` is a legacy default and rarely exists in development environments.
- This causes "Can't locate Sauron/DB.pm" errors even if the files are in the current directory.

## Workarounds
1. **Command Line:** Prepend `perl -I.` to execution:
   `perl -I. ./createtables`
2. **Environment Variable:** Set `PERL5LIB` to the project root:
   `export PERL5LIB=$HOME/sauron`

## Production vs. Development
- **Development:** Use `PERL5LIB` or `perl -I.` to work directly on source files.
- **Production:** The `make install` process uses `sed` to update these paths to the final `--prefix` destination.

## Related
- [[Environment-Setup]]
- [[NetAddr-IP-Syntax-Fix]]
