# Barman Cloud Plugin

This directory contains the Barman Cloud Plugin installation for CloudNativePG.

## Installation

The plugin is installed via the manifest from the official GitHub releases. The manifest has been updated to use the `postgresql-system` namespace (matching the CloudNativePG operator namespace).

## Version

Current version: **v0.9.0**

## Updating

To update to a newer version:

1. Download the latest manifest:

   ```bash
   curl -sL https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v<VERSION>/manifest.yaml | \
     sed 's/namespace: cnpg-system/namespace: postgresql-system/g' > \
     kubernetes/apps/postgresql-system/barman-cloud-plugin/app/manifest.yaml
   ```

2. Replace `<VERSION>` with the desired version (e.g., `v0.10.0`)

3. Commit and push the changes

## Requirements

- CloudNativePG operator version 1.26 or newer (currently running 1.27.1)
- cert-manager installed and operational
- Plugin must be in the same namespace as CloudNativePG operator (`postgresql-system`)

## Documentation

- [Installation Guide](https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/)
- [Usage Guide](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/)
