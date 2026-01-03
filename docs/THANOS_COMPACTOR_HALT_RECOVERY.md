---
# Thanos Compactor Halt Recovery

This runbook documents how to recover when the Thanos compactor sets `thanos_compact_halted == 1` and stops compacting.

## Symptoms

- Alert: `ThanosCompactorHalted`
- Compactor logs contain: `critical error detected; halting`

## Safety notes

- Prefer **marking redundant blocks for deletion** over deleting immediately.
  - This cluster runs compactor with `--delete-delay=48h`, so deletion is delayed (safer for queries and cache consistency).
- Use **`no-compact` marks** only as a temporary guardrail; they prevent compaction progress for the marked blocks.
- Do not remove blocks unless you are confident the time range is covered by a newer compaction output block.

## 1) Identify the failing blocks

From the compactor pod logs, extract ULIDs referenced in the error:

- `kubectl logs -n observability -l app.kubernetes.io/controller=thanos-compactor --tail=300 | grep -iE 'critical error|halting|01[A-Z0-9]{24}'`

## 2) Inspect the bucket around the failing time range

Use the compactor pod to list blocks for a time window:

- `thanos tools bucket ls --objstore.config-file=/etc/thanos/objstore.yaml --output=wide --min-time=<RFC3339> --max-time=<RFC3339>`

To exclude blocks already marked for deletion:

- `thanos tools bucket ls --objstore.config-file=/etc/thanos/objstore.yaml --output=wide --exclude-delete --min-time=<RFC3339> --max-time=<RFC3339>`

If a block is already compacted into a higher compaction level block (`Source: compactor`) for the same time range, the older `Source: sidecar`
blocks are usually safe to mark for deletion.

## 3) Mark redundant blocks for deletion (preferred)

Mark a block for deletion:

- `thanos tools bucket mark --objstore.config-file=/etc/thanos/objstore.yaml --id=<ULID> --marker=deletion-mark.json --details="<why>"`

If the deletion mark already exists, the command will warn; this is usually fine (it means cleanup is already in progress).

## 4) Use `no-compact` only as a temporary unblocker (optional)

If the compactor is repeatedly halting on the same ULIDs and you need to restore compaction progress quickly, mark the specific ULIDs as `no-compact`:

- `thanos tools bucket mark --objstore.config-file=/etc/thanos/objstore.yaml --id=<ULID> --marker=no-compact-mark.json --details="<why>"`

Once the underlying overlap/corruption is resolved (e.g., redundant blocks deleted or the compaction succeeds after upgrade),
remove the marker:

- `thanos tools bucket mark --objstore.config-file=/etc/thanos/objstore.yaml --id=<ULID> --marker=no-compact-mark.json --remove`

## 5) Restart the compactor if it is stuck halted

The compactor can remain halted until it restarts. The preferred way in this repo is GitOps:

- Make a minimal HelmRelease change (e.g., a harmless arg tweak) and let Flux roll the pod, or force a HelmRelease reconcile.

## 6) Verify recovery

- Confirm the compactor is actively compacting and not halting:
  - Look for `compacted blocks` and absence of `critical error detected; halting` in logs.
- Confirm alert clears:
  - `thanos_compact_halted` returns to `0`.


