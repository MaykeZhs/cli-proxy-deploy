# Cursor Bridge Internal POC Design

**Status:** Approved for internal staging only on 2026-08-14

## Decision

Adopt `anyrobert/cursor-api-proxy` only as an optional Cursor Bridge experiment.
Do not merge its source into CLIProxyAPI or expose it as a public service.

The proof of concept is split into two gates:

1. **Stage A — Bridge validation:** run the pinned bridge by itself on a
   loopback-only host port and verify authentication, model discovery, streaming,
   process cleanup, safe workspace behavior, logging, and resource use.
2. **Stage B — Staging CPA integration:** only after Stage A passes, connect a
   separate staging CPA to the bridge over a dedicated Docker network and verify
   CPA provider authentication, model mapping, streaming, retries, and errors.

Stage B requires a separate design/implementation plan after Stage A evidence is
reviewed. The live CPA container is not part of either stage.

## Purpose

The POC answers whether Cursor Bridge can become a safe internal provider behind
CPA. It is not a production deployment and it is not a public Cursor resale API.

Required evidence:

- the bridge accepts a dedicated Bearer key and rejects missing credentials;
- the official Cursor key remains inside the bridge container;
- model discovery returns at least one model;
- synchronous and streaming text completions work;
- client disconnects terminate Cursor CLI child processes;
- safe mode prevents real workspace, MCP, force, agent, and plan access;
- secrets and prompt content do not appear in normal logs;
- container memory, CPU, and PID use remain bounded;
- the source commit, built image ID, Cursor CLI version, and build limitations are
  recorded.

## Architecture

### Stage A

```text
Operator workstation
    -> SSH tunnel or server-local curl
    -> 127.0.0.1:18765
    -> cursor-bridge-poc:8765
    -> official Cursor service
```

There is no Nginx route, public hostname, CPA connection, CPAMP connection, host
workspace mount, Docker socket mount, or shared production volume.

### Stage B target, not implemented by the Stage A plan

```text
Operator workstation
    -> SSH tunnel
    -> staging CPA on 127.0.0.1 only
    -> internal guard
    -> cursor-bridge-poc:8765
    -> official Cursor service
```

The internal guard must enforce an 8 MiB request limit, one concurrent request,
an endpoint allowlist, and removal of `X-Cursor-Mode` and
`X-Cursor-Workspace`. The guard and exact CPA `openai-compatibility` schema are
deferred until Stage A passes.

## Authentication

Three credentials have separate owners:

| Connection | Credential | Storage |
|---|---|---|
| POC client to bridge | `CURSOR_BRIDGE_API_KEY` | protected local POC env file and operator memory |
| Bridge to Cursor | `CURSOR_API_KEY` | protected local POC env file and bridge environment |
| Future client to staging CPA | staging CPA API key | future Stage B config only |

Rules:

- never reuse the live CPA API key, CPA management key, or Cursor key;
- keep `poc.env` mode `0600` inside a mode `0700` directory;
- never pass credentials as command-line arguments;
- never print credentials in status, Doctor, logs, screenshots, or metadata;
- the upstream project has no `_FILE` secret support, so Docker inspection can
  reveal container environment variables. This is accepted for Stage A only and
  is a production STOP condition.

## Pinned upstream contract

- Repository: `https://github.com/anyrobert/cursor-api-proxy`
- Audited source commit:
  `c0ff1f941215027c0a8f658ca5d01f806559208f`
- Local POC image tag: `cursor-api-proxy:poc-c0ff1f9`
- Internal container port: `8765`
- Authentication header: `Authorization: Bearer $CURSOR_BRIDGE_API_KEY`

Supported acceptance endpoints:

- `GET /healthz` — unauthenticated liveness only;
- `GET /health` — authenticated safe configuration summary;
- `GET /v1/models` — authenticated model discovery;
- `POST /v1/chat/completions` — required synchronous and streaming test;
- `POST /v1/responses` — exploratory, not a Stage A promotion requirement;
- `POST /v1/messages` — exploratory, not a Stage A promotion requirement.

Unsupported product capabilities:

- `/v1/completions`;
- `/v1/embeddings`;
- native agent-framework tool calls;
- accurate token accounting or customer billing;
- real multimodal image handling;
- public or paid third-party service;
- multi-account pooling or quota avoidance;
- `reset-hwid` in any form.

## Safe runtime profile

The POC fixes these settings server-side:

```dotenv
CURSOR_BRIDGE_HOST=0.0.0.0
CURSOR_BRIDGE_PORT=8765
CURSOR_BRIDGE_DEFAULT_MODEL=auto
CURSOR_BRIDGE_TIMEOUT_MS=300000
CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE=true
CURSOR_BRIDGE_MODE=ask
CURSOR_BRIDGE_FORCE=false
CURSOR_BRIDGE_APPROVE_MCPS=false
CURSOR_BRIDGE_STRICT_MODEL=true
CURSOR_BRIDGE_VERBOSE=false
CURSOR_BRIDGE_MAX_MODE=false
CURSOR_BRIDGE_USE_ACP=true
CURSOR_BRIDGE_PROMPT_VIA_STDIN=true
CURSOR_BRIDGE_ACP_RAW_DEBUG=false
CURSOR_BRIDGE_CONTEXT_PREAMBLE=true
CURSOR_BRIDGE_MULTI_PORT=false
```

The following variables stay unset:

- `CURSOR_CONFIG_DIRS`;
- `CURSOR_ACCOUNT_DIRS`;
- Cursor Bridge TLS variables;
- `CURSOR_BRIDGE_CONTEXT_EXTRA`;
- `NODE_DEBUG`.

`CURSOR_BRIDGE_HOST=0.0.0.0` applies only inside the container. Docker publishes
the POC port as `127.0.0.1:18765:8765`, so the service is not externally
reachable.

## Container controls

Stage A limits:

```text
CPU:                 2 cores
Memory:              2 GiB
Memory reservation:  512 MiB
PID limit:            128
Request timeout:      300 seconds
Stop grace period:    30 seconds
Docker log rotation:  10 MiB x 5 files
```

Required controls:

- upstream non-root `app` user;
- `init: true`;
- `cap_drop: ALL`;
- `no-new-privileges:true`;
- no host workspace or credential-volume mounts;
- no `read_only` root filesystem until Cursor CLI writable paths are audited;
- sequential Stage A smoke tests only because the upstream app has no global
  concurrency limit.

## Stage A acceptance gates

Stage A passes only when all items pass:

1. The built image is labeled with the exact source commit and its image ID is
   recorded.
2. The host binding is exactly `127.0.0.1:<selected-port>` and a remote host
   cannot reach it.
3. The container runs as user `app` with cap drop, no-new-privileges, memory,
   CPU, and PID limits.
4. `/healthz` returns `ok`.
5. Unauthenticated `/v1/models` returns `401`.
6. Authenticated `/health` reports `ask`, `force=false`, and
   `approveMcps=false`.
7. Authenticated `/v1/models` returns a non-empty model list.
8. One synchronous completion returns the required marker.
9. One streaming completion produces SSE data.
10. `/v1/embeddings` returns `404`.
11. A client disconnect leaves no orphan Cursor CLI process.
12. Logs contain neither POC credential and do not contain request/response
    bodies with verbose mode disabled.
13. Restart count stays unchanged, no OOM kill occurs, and PID usage stays below
    96 during sequential smoke tests.
14. The operator records `agent --version`, `agent --list-models`, the image ID,
    and the known mutable Node/Cursor-installer limitation.

## Immediate STOP conditions

Stop and remove the POC container if any condition occurs:

- the port binds to `0.0.0.0` or a public interface;
- bridge authentication is disabled, reused, or logged;
- a request reaches a real host workspace;
- agent, plan, MCP approval, force, or account-pool behavior becomes active;
- the bridge key or Cursor key appears in logs or committed files;
- a disconnected client leaves a child process running;
- memory/PID growth is unbounded or an OOM/restart occurs;
- upstream source no longer matches the pinned commit;
- the operator attempts public, shared, paid, or quota-avoidance use.

## Repository responsibility

Stage A lives under `poc/cursor-bridge/` and does not modify the production
`deploy.sh`, `deploy.ps1`, `docker-compose.yml`, `config.yaml`, CPA auth volume,
Sub2API, CPAMP, install scripts, or Nginx configuration.

The root project documents and tests the experiment, but does not vendor the
upstream source. The source is built directly from the exact Git commit. The
missing root license file and mutable upstream Docker build remain production
blockers.

## Review checkpoint

After Stage A evidence is complete, the project lead decides one of:

- **NO-GO:** destroy the POC and keep CPA unchanged;
- **REWORK:** patch or fork the bridge before another isolated Stage A run;
- **GO TO STAGE B:** write a separate staging-CPA integration design and plan.

## Audit references

- [Audited upstream commit](https://github.com/anyrobert/cursor-api-proxy/tree/c0ff1f941215027c0a8f658ca5d01f806559208f)
- [Request routing and authentication order](https://github.com/anyrobert/cursor-api-proxy/blob/c0ff1f941215027c0a8f658ca5d01f806559208f/src/lib/request-listener.ts#L39-L156)
- [Environment contract](https://github.com/anyrobert/cursor-api-proxy/blob/c0ff1f941215027c0a8f658ca5d01f806559208f/src/lib/env.ts#L279-L392)
- [Upstream Dockerfile](https://github.com/anyrobert/cursor-api-proxy/blob/c0ff1f941215027c0a8f658ca5d01f806559208f/Dockerfile#L11-L43)
- [Cursor Terms of Service](https://cursor.com/terms-of-service)
