# Changelog

## Unreleased

### Fixed

- Stabilized Docker Compose project naming so the proxy can be restarted after the project folder is renamed or copied.
- Added cleanup for stale stopped `antigravity-proxy` containers left by older Compose project names.
- Documented the container name conflict and auth volume warning in the troubleshooting guide.
- Hid non-credential entries such as `logs` from `bash deploy.sh status`.
