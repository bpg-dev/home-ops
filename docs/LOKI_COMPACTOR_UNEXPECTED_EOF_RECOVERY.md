# Loki Compactor "unexpected EOF" / Retention Never Succeeds

Incident found 2026-10-25, fixed 2026-10-27.

## Symptoms

- Loki (single binary, `-target=all`, TSDB index on the Garage `loki` bucket)
  logs every `compaction_interval` (10 min):
  `msg="failed to compact files" table=loki_index_20631 err="unexpected EOF"`,
  `msg="failed to run compaction" err="unexpected EOF"`,
  `msg="failed to apply retention" err="unexpected EOF"`.
- `loki_compactor_apply_retention_last_successful_run_timestamp_seconds` is 0
  on every pod; `loki_boltdb_shipper_compact_tables_operation_total{status="failure"}`
  increases by 6 per hour (144/day). It had done so since at least
  2026-09-03; nobody noticed until the Loki ruler started evaluating rules
  (`LokiHasWarnOrErrorLogs` fired, see `OBSERVABILITY_MIGRATION_LOKI_THANOS_90D.md`).
- Other tables still compact: the compactor walks tables newest to oldest and
  the error only aborts the run at the bad table, so the live 90-day window
  looked healthy. Tables older than the bad one are never retention-deleted.

## Root cause

Two objects in the `loki` bucket were unservable by Garage: `HEAD` returned
the full `Content-Length`, `GET` closed the stream after 0 bytes
(`curl: (18) transfer closed with N bytes remaining`). `garage block
list-errors` showed nothing. Both were compactor-written index files dated
2026-06-27 19:51 and 20:16 UTC:

- `index/loki_index_20631/fake/1782591414235879639-compactor-...-4a3989ef.tsdb.gz`
- `index/loki_index_20541/fake/1782589914670604234-compactor-...-24df68c5.tsdb.gz`

Table 20631 (2026-06-27) still had its 38 per-ingester `*.tsdb.gz` files
next to the broken compactor file (compaction never finished); table 20541
(2026-03-29) only had the broken file. Both were far past the 90-day
retention and should have been deleted long ago.

## Diagnosis

```bash
export KUBECONFIG=./kubeconfig
# which table fails
kubectl logs -n observability deploy/loki --all-pods=true --since=1h \
  | grep -E 'failed to (compact|apply retention)'

# S3 access: the aws CLI on the Mac is a 1Password alias that injects its own
# key and ignores AWS_* env vars; use curl --aws-sigv4 instead.
K=$(kubectl get secret -n observability loki-secret \
  -o jsonpath='{.data.S3_ACCESS_KEY_ID}' | base64 -d)
S=$(kubectl get secret -n observability loki-secret \
  -o jsonpath='{.data.S3_SECRET_ACCESS_KEY}' | base64 -d)
E=https://s3.${SECRET_DOMAIN}        # path-style, envoy-internal
T=index/loki_index_20631/
curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user "$K:$S" \
  "$E/loki?list-type=2&prefix=$T" \
  | sed -E 's#<Contents>#\n#g' | grep -oE '<Key>[^<]+|<Size>[0-9]+'
# download each file and gzip -t it; an unservable one yields 0 bytes
curl -sS --http1.1 --aws-sigv4 "aws:amz:us-east-1:s3" --user "$K:$S" \
  -o /tmp/x.gz "$E/loki/<key>" && gzip -t /tmp/x.gz
```

A healthy compacted table is a single `index/<table>/fake/<ts>-compactor-...tsdb.gz`.

## Fix

Delete only the unservable object(s). Loki's next cycle re-compacts the
remaining ingester files and retention deletes the whole table (it is older
than `retention_period`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE \
  --aws-sigv4 "aws:amz:us-east-1:s3" --user "$K:$S" "$E/loki/<key>"
```

Verify within one cycle: `kubectl logs ... | grep -c level=error` is 0,
`loki_compactor_apply_retention_last_successful_run_timestamp_seconds` is a
recent timestamp, `loki_compactor_apply_retention_operation_total{status="success"}`
increments, oldest `index/loki_index_<N>/` prefix equals today minus 90 days.

## Notes

- The Claude Code auto-mode classifier refuses an S3 `DELETE` in the same
  command as reading the secret; a human ran the delete.
- Why Garage lost two blocks on 2026-06-27 is unknown; nothing else in the
  bucket is dated that day. If more `unexpected EOF` tables appear, check
  `garage block list-errors` and consider `garage repair blocks`.
- The compactor file names encode `<created-ns>-compactor-<minTs>-<maxTs>-<hash>`;
  the table number is days since epoch (`date -u -r $((N*86400))`).
