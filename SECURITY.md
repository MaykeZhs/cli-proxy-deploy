# Security

This project stores local secrets outside Git by default.

Do not commit:

- `config.yaml`
- `.env`
- `sub2api.env`
- `cursor-bridge.env`
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

## Optional Cursor Bridge sidecar

The live Cursor Bridge is an optional sidecar beside an already-running
`cli-proxy-manager`. It is not part of the default deploy wizard.

Boundary:

- Clients keep using the existing CPA API key. They never send `CURSOR_API_KEY`
  or `crsr_` to CPA.
- CPA talks only to `cursor-bridge-guard:8080` on `cpa-cursor-bridge`. It must
  not join `cursor-bridge-backend` and must not reach `:8765`.
- The guard allows `GET /v1/models` and `POST /v1/chat/completions` only, caps
  the body at 8 MiB, and allows one in-flight proxied connection.
- The bridge and guard publish no host ports. Do not bind `0.0.0.0:8765` or
  `0.0.0.0:18765`, and do not put the live Nginx in front of either port.
- Keep `cursor-bridge.env` mode `0600`. Use different values for
  `CURSOR_API_KEY` and `CURSOR_BRIDGE_API_KEY`. Never reuse `CPA_API_KEY` or
  `CPA_MANAGEMENT_KEY`.
- First version is one Cursor key and one Cursor identity. Do not set
  `CURSOR_CONFIG_DIRS`, `CURSOR_ACCOUNT_DIRS`, or `CURSOR_BRIDGE_MULTI_PORT`.

The upstream image still puts keys in container environment (visible to
`docker inspect`) and still installs Cursor CLI with `curl | bash` at image
build time. That is accepted for this private sidecar and is a blocker for any
public, shared, or paid product.

Do not recreate `cli-proxy-manager` or delete `cli-proxy-manager-auth` to attach
or remove this sidecar. Public, shared, paid, multi-account, quota-avoidance,
`reset-hwid`, agent, plan, MCP, force, and real-workspace uses are STOP
conditions.

## Experimental Cursor Bridge POC

The Cursor Bridge POC is internal and disposable. It binds only to loopback and
must not be connected to Nginx, the live CPA container, CPAMP, Sub2API, a public
hostname, or a host workspace. Keep `poc/cursor-bridge/poc.env` mode `0600` and
use different values for `CURSOR_API_KEY` and `CURSOR_BRIDGE_API_KEY`.

The audited upstream commit processes dashboard/control routes before bridge-key
authentication and reads request bodies without an application size limit.
Loopback-only exposure and sequential operator tests are mandatory. Public,
shared, paid, multi-account, quota-avoidance, `reset-hwid`, agent, plan, MCP,
force, real-workspace, and billing uses are outside this POC and are production
STOP conditions.
