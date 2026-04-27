# Security

This project stores local secrets outside Git by default.

Do not commit:

- `config.yaml`
- `.env`
- OAuth credential JSON files
- Docker volume backups for `antigravity-proxy-auth`

If a key or OAuth credential is exposed, rotate it immediately:

1. Stop the service with `bash deploy.sh stop`.
2. Remove or replace the exposed local file.
3. Re-run `bash deploy.sh` or `bash deploy.sh login`.
4. Restart with `bash deploy.sh restart`.

For public GitHub sharing, keep examples generic and never paste real API keys,
OAuth email addresses, credential filenames, or screenshots containing tokens.
