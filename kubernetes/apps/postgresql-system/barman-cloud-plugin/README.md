# Barman Cloud Plugin

This directory contains the Barman Cloud Plugin installation for CloudNativePG.

## Installation

The plugin is installed via the manifest from the official GitHub releases. The manifest has been updated to use the `postgresql-system` namespace (matching the CloudNativePG operator namespace).

## Version

Current version: **v0.12.0**

## Updating

The manifest must be re-downloaded in full — it contains a base64-encoded
`SIDECAR_IMAGE` secret that Renovate cannot rewrite, so a partial bump of
only the operator container image leaves the injected sidecar stuck at the
old version. Renovate is disabled on this file (see `.renovaterc.json5`).

1. Download the latest manifest:

   ```bash
   curl -sL https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v<VERSION>/manifest.yaml | \
     sed 's/namespace: cnpg-system/namespace: postgresql-system/g' > \
     kubernetes/apps/postgresql-system/barman-cloud-plugin/app/manifest.yaml
   ```

2. Replace `<VERSION>` with the desired version (e.g., `v0.13.0`)

3. Commit, push, and let Flux reconcile.

4. Restart the plugin operator so it re-reads the new `SIDECAR_IMAGE`:

   ```bash
   kubectl rollout restart deploy barman-cloud -n postgresql-system
   ```

5. Recreate the postgres pods (replicas first, primary last) so the operator
   injects the new sidecar image.

## Requirements

- CloudNativePG operator version 1.26 or newer (currently running 1.27.1)
- cert-manager installed and operational
- Plugin must be in the same namespace as CloudNativePG operator (`postgresql-system`)

## Documentation

- [Installation Guide](https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/)
- [Usage Guide](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/)
