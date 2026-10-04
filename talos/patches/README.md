# Talos Patching

This directory contains Kustomization patches that are added to the talhelper configuration file.

<https://www.talos.dev/v1.7/talos-guides/configuration/patching/>

## Patch Directories

Under this `patches` directory, there are several sub-directories that can contain patches that are added to the talhelper configuration file.
Each directory is optional and therefore might not created by default.

- `global/`: patches that are applied to both the controller and worker configurations
- `controller/`: patches that are applied to the controller configurations
- `worker/`: patches that are applied to the worker configurations
- `${node-hostname}/`: patches that are applied to the node with the specified name

## Notes (2026-10-04)

- talhelper 3.1.x renders multi-document machine configs for Talos 1.13 and rejects
  RFC6902 patches (`op: remove`). Use strategic-merge deletes instead, e.g.
  `controller/admission-controller-patch.yaml`. Because talhelper runs envsubst on
  patch files, a literal `$patch` must be written as `$$patch`.
- The regenerated configs under `clusterconfig/` are NOT a no-op against the live
  nodes: talhelper now emits the network as `HostnameConfig`/`LinkAliasConfig`/
  `Layer2VIPConfig`/`LinkConfig` documents, drops deprecated v1alpha1 fields
  (`rbac`, `stableHostname`, `apidCheckExtKeyUsage`, `disablePodSecurityPolicy`) and
  adds `grubUseUKICmdline: true` and a `1.1.1.1` nameserver. `talosctl apply-config
  --dry-run` reports a reboot. Review that diff and apply one node at a time before
  using `task talos:apply-node` again. `task talos:upgrade-node` and
  `talosctl upgrade-k8s` do not depend on these files.
