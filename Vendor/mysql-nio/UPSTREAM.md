# Upstream

Source: https://github.com/vapor/mysql-nio

Version: 1.9.3, commit `3cd7153792ab259a217507b775c14d9ddba3f79f`

License: MIT (see LICENSE). Sources, tests and package manifest are preserved here for reproducible builds with these small compatibility fixes:

- `MySQLConnectionHandler.doInitialAuthPluginHandling`: send an empty response for an empty `caching_sha2_password` password, matching MySQL's protocol. The upstream implementation hashes the empty string and fails authentication on MySQL 8/9 accounts without a password. Covered by Harbor's integration tests.

This is a local source dependency, not a separately maintained public fork. Re-evaluate these changes when updating MySQLNIO.
