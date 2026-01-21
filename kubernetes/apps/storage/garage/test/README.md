# Garage Storage Benchmark

## Purpose

Compare `ceph-rbd` vs `openebs-hostpath` for Garage workloads before converting to multi-node StatefulSet.

## Usage

```bash
# Apply benchmark resources
kubectl apply -f kubernetes/apps/storage/garage/test/benchmark.yaml

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/storage-bench -n storage --timeout=120s

# Exec into pod
kubectl exec -it -n storage storage-bench -- sh
```

## Benchmark Commands

### Test 1: LMDB-like workload (metadata) - random 4K I/O

```bash
# Ceph RBD
fio --name=meta-ceph --directory=/ceph --size=1G --bs=4k \
    --rw=randrw --rwmixread=70 --ioengine=libaio --direct=1 \
    --numjobs=4 --iodepth=32 --runtime=60 --time_based

# OpenEBS Hostpath
fio --name=meta-hostpath --directory=/hostpath --size=1G --bs=4k \
    --rw=randrw --rwmixread=70 --ioengine=libaio --direct=1 \
    --numjobs=4 --iodepth=32 --runtime=60 --time_based
```

### Test 2: Data blocks - sequential I/O

```bash
# Ceph RBD
fio --name=data-ceph --directory=/ceph --size=2G --bs=1M \
    --rw=write --ioengine=libaio --direct=1 --numjobs=2 --runtime=60

# OpenEBS Hostpath
fio --name=data-hostpath --directory=/hostpath --size=2G --bs=1M \
    --rw=write --ioengine=libaio --direct=1 --numjobs=2 --runtime=60
```

## Decision Criteria

| Workload | Priority | Likely Winner |
|----------|----------|---------------|
| Metadata (random 4K) | Latency, IOPS | `openebs-hostpath` (no network hop) |
| Data blocks (sequential) | Throughput | Either (both fast for sequential) |
| Data safety | Replication | `ceph-rbd` (Ceph replicates), but Garage also replicates |

**Note**: With Garage's `replication_factor=2`, data is replicated at application level regardless of storage choice. `openebs-hostpath` is viable since Garage handles redundancy.

## Cleanup

```bash
kubectl delete -f kubernetes/apps/storage/garage/test/benchmark.yaml
```
