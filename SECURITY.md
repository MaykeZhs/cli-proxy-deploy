# Security

This project stores local secrets outside Git by default.

Do not commit:

- `config.yaml`
- `.env`
- `sub2api.env`
- OAuth credential JSON files
- Docker volume backups for `cli-proxy-manager-auth`
- Backups of the `sub2api-manager-data`, `sub2api-manager-postgres`, and
  `sub2api-manager-redis` volumes

If a key or OAuth credential is exposed, rotate it immediately:

1. Stop the service with `bash deploy.sh stop`.
2. Remove or replace the exposed local file.
3. Re-run `bash deploy.sh` or `bash deploy.sh login`.
4. Restart with `bash deploy.sh restart`.

For public GitHub sharing, keep examples generic and never paste real API keys,
OAuth email addresses, credential filenames, or screenshots containing tokens.

## CPA Management and plugin resources

`capabilities` and Doctor use authenticated Management API GET requests only when
a plaintext `CPA_MANAGEMENT_KEY` is already available locally. They never print
or return that key. Without a key, protected `/v0/management/...` routes are not
probed because repeated unauthenticated requests can trigger CPA's temporary ban.

For the audited CLIProxyAPI `v7.2.102` route contract, resources under
`/v0/resource/plugins/...` do not use Management API authentication. Treat a
direct-public HTTP deployment with remote management enabled as critical: put the
service behind HTTPS and access controls, or block those resource paths upstream.

Sub2API binds to `127.0.0.1` by default and selects a free high host port on
first deployment. If you change `SUB2API_BIND_HOST=0.0.0.0`, protect the selected
port with a firewall and an HTTPS reverse proxy. Managed PostgreSQL and Redis are
intentionally not published to the host. Keep external database and Redis
credentials private in `sub2api.env`.
