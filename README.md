# OpenShift etcd Control Plane Backup & Restore

Step-by-step guide for backing up and restoring the OpenShift Container Platform control plane (etcd) data. Based on [Red Hat documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/control-plane-backup-and-restore) and verified on a live cluster.

## Cluster Topology (luke test cluster)

| Node | Role | IP |
|------|------|----|
| control01.syangsao.net | control-plane, master, worker | 192.168.40.26 |
| control02.syangsao.net | control-plane, master, worker | 192.168.40.27 |
| arbiter.syangsao.net | arbiter | 192.168.40.25 |

- **OpenShift version**: 4.22.13 (Kubernetes v1.35.6)
- **etcd version**: 3.6.0
- **etcd members**: 3 (control01, control02, arbiter)
- **Proxy**: None configured
- **Machine API**: Yes (no ControlPlaneMachineSet)

> **Note**: This cluster uses an **arbiter** configuration (2 control plane nodes + 1 arbiter = 3 etcd members). The procedures below work for standard 3-node HA clusters as well. Adjust node names accordingly.

---

## Part 1: Backing Up etcd Data

### Prerequisites

- `cluster-admin` access via `oc` CLI
- SSH access to control plane nodes (user `core`)
- No cluster-wide proxy (if proxy is enabled, export `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` in the debug shell)

### Step 1: Verify Proxy Configuration

```bash
oc get proxy cluster -o yaml | grep -E 'httpProxy|httpsProxy|noProxy'
```

If all fields are empty/null, no proxy is configured and you can skip the proxy export step.

### Step 2: Start a Debug Session on a Control Plane Node

Pick **one** control plane node (do NOT run backup on every node). This example uses `control01`:

```bash
oc debug --as-root node/control01.syangsao.net
```

You will get a root shell prompt.

### Step 3: Chroot to the Host

```bash
chroot /host
```

### Step 4 (Optional): Export Proxy Variables

Only if cluster-wide proxy is enabled:

```bash
export HTTP_PROXY=http://<your_proxy.example.com>:8080
export HTTPS_PROXY=https://<your_proxy.example.com>:8080
export NO_PROXY=<example.com>
```

### Step 5: Run the Backup Script

```bash
/usr/local/bin/cluster-backup.sh /home/core/assets/backup
```

**Expected output** (verified on luke cluster):

```
found latest kube-apiserver: /etc/kubernetes/static-pod-resources/kube-apiserver-pod-15
found latest kube-controller-manager: /etc/kubernetes/static-pod-resources/kube-controller-manager-pod-7
found latest kube-scheduler: /etc/kubernetes/static-pod-resources/kube-scheduler-pod-7
found latest etcd: /etc/kubernetes/static-pod-resources/etcd-pod-9
f876660fc8070aa47c55ee74038a0576ec144c7613edc0e19efe3cfa766437ef
etcdctl version: 3.6.13
API version: 3.6
{"level":"info","ts":"2026-10-05T13:54:15.735916Z",...,"msg":"created temporary db file",...}
{"level":"info",...,"msg":"fetched snapshot","endpoint":"https://192.168.40.26:2379","size":"130 MB",...}
Snapshot saved at /home/core/assets/backup/snapshot_2026-10-05_135414.db
Server version 3.6.0
{"hash":1366634493,"revision":15633790,"totalKey":8403,"totalSize":129986560,"version":"3.6.0"}
snapshot db and kube resources are successfully saved to /home/core/assets/backup
```

### Step 6: Verify Backup Files

Exit the debug session (`exit` twice), then verify the files on the node:

```bash
ssh core@control01.syangsao.net 'ls -lh /home/core/assets/backup/'
```

**Expected output**:

```
total 125M
-rw-------. 1 root root 124M Oct  5 13:54 snapshot_2026-10-05_135414.db
-rw-------. 1 root root  85K Oct  5 13:54 static_kuberesources_2026-10-05_135414.tar.gz
```

Two files are created:
- `snapshot_<timestamp>.db` — the etcd snapshot (validated by the script)
- `static_kuberesources_<timestamp>.tar.gz` — static pod resources + encryption keys (if etcd encryption is enabled)

> **Security note**: If etcd encryption is enabled, store the `static_kuberesources` file separately from the snapshot. It contains the encryption keys.

### Step 7: Copy Backup Off-Node

The backup files are root-owned with `0600` permissions. Use `sudo cat` to copy them:

```bash
# Create local directory
mkdir -p ~/etcd-backup/luke

# Copy snapshot (124 MB)
ssh core@control01.syangsao.net 'sudo cat /home/core/assets/backup/snapshot_2026-10-05_135414.db' \
  > ~/etcd-backup/luke/snapshot_2026-10-05_135414.db

# Copy static resources (85 KB)
ssh core@control01.syangsao.net 'sudo cat /home/core/assets/backup/static_kuberesources_2026-10-05_135414.tar.gz' \
  > ~/etcd-backup/luke/static_kuberesources_2026-10-05_135414.tar.gz

# Verify
ls -lh ~/etcd-backup/luke/
```

> **Important**: Store backups in a secure location outside the OpenShift cluster. Do not keep them only on control plane nodes.

### Backup Best Practices

- Take backups during non-peak hours (high I/O cost)
- Take a backup before every cluster update
- Use the same z-stream release for restore (e.g., 4.22.13 backup → 4.22.13 restore)
- Do NOT take a backup before the first certificate rotation completes (24h after install)

---

## Part 2: Restoring to an Earlier Cluster State

> **WARNING**: Restoring to an earlier cluster state is a **destructive and destabilizing** action. It takes the cluster back in time, causing all clients to experience a conflicting, parallel history. This can cause Operator churn, PV tracking issues, and in extreme cases, workload deletion or machine reimaging. **Use only as a last resort.**

### When to Use Restore

- The cluster has lost the majority of control plane hosts and quorum
- An administrator has deleted something critical and must restore

If you can retrieve data using the Kubernetes API server, etcd is available and you should **not** restore from backup.

### Prerequisites

- `cluster-admin` access via certificate-based `kubeconfig`
- SSH access to **all** control plane hosts (user `core`)
- A backup directory containing both files:
  - `snapshot_<datetimestamp>.db`
  - `static_kuberesources_<datetimestamp>.tar.gz`
- A healthy control plane host to use as the recovery host

### Step 1: Select a Recovery Host

Pick one control plane node as the recovery host. This example uses `control01`. The other nodes (control02, arbiter) are non-recovery nodes.

### Step 2: Establish SSH Connectivity to ALL Control Plane Nodes

**Critical**: `kube-apiserver` becomes inaccessible after the restore starts. You **must** have active SSH sessions to every control plane node before proceeding. Open separate terminals for each node:

```bash
# Terminal 1 - Recovery host
ssh core@control01.syangsao.net

# Terminal 2 - Non-recovery node 1
ssh core@control02.syangsao.net

# Terminal 3 - Non-recovery node 2 (arbiter)
ssh core@arbiter.syangsao.net
```

> **If you do not complete this step, you will lose access to the control plane hosts and be unable to recover the cluster.**

### Step 3: Disable etcd on ALL Control Plane Nodes

On **each** control plane node (all three terminals), run:

```bash
sudo -E /usr/local/bin/disable-etcd.sh
```

**Expected output** (on each node):

```
...stopping etcd-pod.yaml
Waiting for container etcd to stop
............................complete
Waiting for container etcdctl to stop
..complete
Waiting for container etcd-metrics to stop
complete
Waiting for container etcd-readyz to stop
complete
Waiting for container etcd-rev to stop
complete
```

### Step 4: Copy Backup to Recovery Host

On the **recovery host** (control01), copy the backup directory:

```bash
# From your workstation, copy the backup files to the recovery host:
ssh core@control01.syangsao.net 'sudo mkdir -p /home/core/assets/backup && sudo chown core:core /home/core/assets/backup'

# Copy snapshot (adjust filenames to match your backup)
ssh core@control01.syangsao.net 'sudo tee /home/core/assets/backup/snapshot_2026-10-05_135414.db > /dev/null' \
  < ~/etcd-backup/luke/snapshot_2026-10-05_135414.db

# Copy static resources
ssh core@control01.syangsao.net 'sudo tee /home/core/assets/backup/static_kuberesources_2026-10-05_135414.tar.gz > /dev/null' \
  < ~/etcd-backup/luke/static_kuberesources_2026-10-05_135414.tar.gz

# Verify
ssh core@control01.syangsao.net 'ls -lh /home/core/assets/backup/'
```

### Step 5: Run the Restore Script on the Recovery Host

On the **recovery host** (control01), run:

```bash
sudo -E /usr/local/bin/cluster-restore.sh /home/core/assets/backup
```

**Expected output** (verified on luke cluster):

```
1fc64843404579a5c8d4f986de0f65fc6a096d1a7626f901f5000da9c44e5d55
etcdctl version: 3.6.13
API version: 3.6
{"hash":1366634493,"revision":15633790,"totalKey":8403,"totalSize":129986560,"version":"3.6.0"}
...stopping etcd-pod.yaml
Waiting for container etcd to stop
...........................complete
Waiting for container etcdctl to stop
..complete
Waiting for container etcd-metrics to stop
complete
Waiting for container etcd-readyz to stop
complete
Waiting for container etcd-rev to stop
complete
Moving etcd data-dir /var/lib/etcd/member to /var/lib/etcd-backup
starting restore-etcd static pod
==============================================================================
SNAPSHOT RESTORE COMPLETED
==============================================================================
NEXT STEPS: Monitor the rollout from a system with 'oc' access:
1. Check if the etcd operator completes the rollout successfully:
    $ oc adm wait-for-stable-cluster  # OR oc get co/etcd -w
...
```

The script:
1. Validates the snapshot
2. Stops the existing etcd static pod
3. Moves the old etcd data to `/var/lib/etcd-backup`
4. Extracts the backup's static pod resources
5. Copies the snapshot to the backup directory
6. Starts a `restore-etcd` static pod that performs the snapshot restore

### Step 6: Monitor Recovery

From your workstation (with `oc` access):

```bash
# Wait for the cluster to stabilize (can take up to 15 minutes)
oc adm wait-for-stable-cluster

# OR monitor the etcd operator
oc get co/etcd -w
```

### Step 7: Turn Off the Quorum Guard

Once the API responds, disable the etcd Operator quorum guard so it can roll out the remaining members:

```bash
oc patch etcd/cluster --type=merge \
  -p '{"spec": {"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true}}}'
```

### Step 8: Monitor Recovery Again

```bash
oc adm wait-for-stable-cluster
```

### Step 9: Re-enable the Quorum Guard

Once fully recovered, re-enable the quorum guard:

```bash
oc patch etcd/cluster --type=merge \
  -p '{"spec": {"unsupportedConfigOverrides": null}}'
```

Verify it was removed:

```bash
oc get etcd/cluster -o yaml | grep unsupportedConfigOverrides
# Should return nothing (or be absent)
```

### Step 10: Verify Recovery

```bash
# Check all nodes are Ready
oc get nodes

# Check etcd pods are running
oc get pods -n openshift-etcd -l k8s-app=etcd

# Check etcd member health
oc rsh -n openshift-etcd etcd-control01.syangsao.net etcdctl endpoint health

# Check etcd members (should show 3 members)
oc rsh -n openshift-etcd etcd-control01.syangsao.net etcdctl member list -w table

# Check all cluster operators are available
oc get clusteroperators
```

### Troubleshooting: Force Redeployment

If the etcd static pods are not rolling out, force a redeployment:

```bash
oc patch etcd cluster \
  -p='{"spec": {"forceRedeploymentReason": "recovery-'"$(date --rfc-3339=ns)"'"}}' \
  --type=merge
```

### Troubleshooting: Manually Restart Static Pods

If `/var/lib/etcd/revision.json` is not being re-created on the recovery host:

```bash
ssh core@control01.syangsao.net 'sudo mv /etc/kubernetes/manifests/etcd-pod.yaml /tmp/ && sleep 30 && sudo mv /tmp/etcd-pod.yaml /etc/kubernetes/manifests/'
```

---

## Part 3: Testing the Restore Procedure (Simulated Failure)

Red Hat provides a documented procedure to test your restore workflow by simulating etcd failure on non-recovery nodes. **Only do this on a non-production cluster.**

### Prerequisites

- SSH access to all control plane hosts
- A recent etcd backup
- **Non-production cluster** (this is destructive)

### Step 1: Simulate etcd Failure on Non-Recovery Nodes

On each **non-recovery** node (control02 and arbiter in this example):

```bash
# Disable etcd
sudo /usr/local/bin/disable-etcd.sh

# Delete etcd variable data
sudo rm -rf /var/lib/etcd

# Disable the kubelet service
sudo systemctl disable kubelet.service --now
```

### Step 2: Verify Non-Recovery Nodes Are Not Ready

From your workstation:

```bash
oc get nodes
# control02 and arbiter should show NotReady
```

### Step 3: Restore from Backup

Follow **Part 2** (Steps 1–10) to restore the cluster.

### Step 4: Re-enable kubelet on Non-Recovery Nodes

After the API responds and the restore is complete:

```bash
# On each non-recovery node:
ssh core@control02.syangsao.net 'sudo systemctl enable kubelet.service --now'
ssh core@arbiter.syangsao.net 'sudo systemctl enable kubelet.service --now'
```

### Step 5: Verify Full Recovery

```bash
oc get nodes
# All nodes should be Ready

oc get pods -n openshift-etcd
# All etcd pods should be Running
```

---

## Part 4: Disaster Recovery — Restoring etcd Quorum (HA Clusters)

If the cluster has lost quorum (majority of control plane hosts down), you can restore quorum **without a backup** using the `quorum-restore.sh` script. This creates a new single-member etcd cluster from the local data directory on a recovery host.

> **WARNING**: You might experience data loss if the recovery host does not have all data replicated to it.

### Prerequisites

- SSH access to at least one healthy control plane node
- The cluster has lost quorum (API is read-only or unresponsive)

### Step 1: Select a Recovery Host

Pick a control plane host that is still running and has the most up-to-date etcd data.

### Step 2: Run quorum-restore.sh

On the recovery host, via SSH:

```bash
sudo -E /usr/local/bin/quorum-restore.sh
```

The script:
1. Stops the existing etcd static pod
2. Creates a new single-member etcd cluster from the local data directory
3. Starts the `restore-etcd` static pod

### Step 3: Verify Local etcd Container

```bash
sudo crictl ps --name '^etcd$'
```

### Step 4: Re-create Offline Nodes

For each offline control plane node, delete and re-create the machine (one at a time):

```bash
# Get the machine for an offline node
oc get machines -n openshift-machine-api -o wide

# Delete the machine (a new one is automatically provisioned)
oc delete machine <machine_name> -n openshift-machine-api

# Verify the new machine is created
oc get machines -n openshift-machine-api -o wide
```

> **Do NOT delete and re-create the machine for the recovery host.**

### Step 5: Wait for Recovery

```bash
oc adm wait-for-stable-cluster
# Can take up to 15 minutes
```

---

## Part 5: Replacing etcd Members

### Replacing a Healthy etcd Member

For planned hardware maintenance. Take an etcd backup first.

1. List control plane machines:
   ```bash
   oc get machines -l machine.openshift.io/cluster-api-machine-role=master -n openshift-machine-api
   ```

2. Delete the machine (one at a time):
   ```bash
   oc delete machine <machine_name> -n openshift-machine-api
   ```

3. Monitor:
   ```bash
   oc get machines -l machine.openshift.io/cluster-api-machine-role=master -n openshift-machine-api -o wide
   oc get clusteroperator etcd
   oc get nodes -l node-role.kubernetes.io/control-plane
   ```

4. Verify etcd health:
   ```bash
   oc rsh -n openshift-etcd <etcd_pod_name>
   etcdctl endpoint health
   etcdctl member list -w table
   ```

### Replacing an Unhealthy etcd Member

1. Identify the unhealthy member:
   ```bash
   oc get etcd -o=jsonpath='{range .items[0].status.conditions[?(@.type=="EtcdMembersAvailable")]}{.message}{"\n"}{end}'
   ```

2. Determine the state (machine stopped, node NotReady, or pod crashlooping)

3. Follow the appropriate procedure from the [Red Hat documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/control-plane-backup-and-restore#replacing-unhealthy-etcd-member_replacing-unhealthy-etcd-member)

---

## Part 6: Automated etcd Backups (Technology Preview)

> **WARNING**: Automated etcd backups are a **Technology Preview** feature. They require the `TechPreviewNoUpgrade` feature set, which **prevents minor version updates** and **cannot be disabled**. Do not use on production clusters.

### Enable the Feature Gate

```yaml
# enable-tech-preview-no-upgrade.yaml
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: TechPreviewNoUpgrade
```

```bash
oc apply -f enable-tech-preview-no-upgrade.yaml
```

Verify the CRD is created:

```bash
oc get crd | grep backup
# backups.config.openshift.io
# etcdbackups.operator.openshift.io
```

### Single Automated Backup (Dynamic Storage)

```yaml
# etcd-backup-pvc.yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: etcd-backup-pvc
  namespace: openshift-etcd
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 200Gi
  volumeMode: Filesystem
```

```yaml
# etcd-single-backup.yaml
apiVersion: operator.openshift.io/v1alpha1
kind: EtcdBackup
metadata:
  name: etcd-single-backup
  namespace: openshift-etcd
spec:
  pvcName: etcd-backup-pvc
```

```bash
oc apply -f etcd-backup-pvc.yaml
oc apply -f etcd-single-backup.yaml
```

### Recurring Automated Backups

```yaml
# etcd-recurring-backup.yaml
apiVersion: config.openshift.io/v1alpha1
kind: Backup
metadata:
  name: etcd-recurring-backup
spec:
  etcd:
    schedule: "20 4 * * *"
    timeZone: "UTC"
    pvcName: etcd-backup-pvc
    retentionPolicy:
      retentionType: RetentionNumber
      retentionNumber:
        maxNumberOfBackups: 5
```

```bash
oc create -f etcd-recurring-backup.yaml
oc get cronjob -n openshift-etcd
```

---

## Known Issues & Lessons Learned (luke cluster testing, 2026-10-05)

### Issue: Kubelet Fails to Start etcd Static Pod After Restore (OCP 4.22)

**Symptom**: After running `cluster-restore.sh` on the recovery host, the kubelet does not start the `restore-etcd` static pod. The API server remains unresponsive indefinitely.

**Root cause**: On OpenShift 4.22 (Kubernetes v1.35), the etcd static pod manifest uses projected volumes (secrets/configmaps) that require the API server to be running. This creates a chicken-and-egg problem: the kubelet cannot start the etcd pod without the API, and the API cannot start without etcd.

**Workaround 1 — ETCD_ETCDCTL_RESTORE mode**: Use the `ETCD_ETCDCTL_RESTORE=1` environment variable when running `cluster-restore.sh`. This mode uses `etcdctl snapshot restore` directly instead of creating a restore-etcd static pod:

```bash
ETCD_ETCDCTL_RESTORE=1 sudo -E /usr/local/bin/cluster-restore.sh /home/core/assets/backup
```

This bypasses the static pod mechanism entirely and restores the snapshot data directly. However, the kubelet still needs to start the original etcd-pod.yaml, which may also hit the same chicken-and-egg problem.

**Workaround 2 — Manual podman start (verified working on luke cluster)**: If the kubelet is stuck, manually start the etcd container using `podman` with host networking and SELinux shared labels. This was verified to restore API access:

```bash
# Run as root on the recovery node
ETCD_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:89e0f7620b82da448889c76bc3c49cbd6c456fe77c8ae41693b0b24169658670"
NODE_IP=$(hostname -I | awk '{print $1}')
ETCD_NAME=$(hostname)
HOST_CERTS="/etc/kubernetes/static-pod-resources/etcd-certs"
CONTAINER_CERTS="/etc/kubernetes/static-pod-certs"

# Step 1: Restore the snapshot data (if not already done by cluster-restore.sh)
mkdir -p /tmp/snap
cp /home/core/assets/backup/snapshot_*.db /tmp/snap/snapshot.db
rm -rf /var/lib/etcd && mkdir -p /var/lib/etcd
podman run --rm \
  -v /tmp/snap:/snap:ro,z \
  -v /var/lib/etcd:/var/lib/etcd:z \
  --entrypoint /usr/bin/etcdutl \
  "$ETCD_IMAGE" \
  snapshot restore /snap/snapshot.db \
    --name="$ETCD_NAME" \
    --initial-cluster="$ETCD_NAME=https://${NODE_IP}:2380" \
    --initial-cluster-token=openshift-etcd-restore \
    --initial-advertise-peer-urls="https://${NODE_IP}:2380" \
    --data-dir=/var/lib/etcd \
    --skip-hash-check=true

# Step 2: Start etcd with host networking and SELinux :z labels
podman run -d \
  --name etcd-manual \
  --network=host \
  -v /var/lib/etcd:/var/lib/etcd:z \
  -v "${HOST_CERTS}":"${CONTAINER_CERTS}":ro,z \
  --entrypoint /bin/sh \
  "$ETCD_IMAGE" \
  -c "exec etcd \
    --logger=zap \
    --log-level=info \
    --initial-advertise-peer-urls=https://${NODE_IP}:2380 \
    --listen-peer-urls=https://${NODE_IP}:2380 \
    --advertise-client-urls=https://${NODE_IP}:2379 \
    --listen-client-urls=https://127.0.0.1:2379,https://${NODE_IP}:2379 \
    --initial-cluster=${ETCD_NAME}=https://${NODE_IP}:2380 \
    --initial-cluster-state=new \
    --data-dir=/var/lib/etcd \
    --cert-file=${CONTAINER_CERTS}/secrets/etcd-all-certs/etcd-serving-${ETCD_NAME}.crt \
    --key-file=${CONTAINER_CERTS}/secrets/etcd-all-certs/etcd-serving-${ETCD_NAME}.key \
    --trusted-ca-file=${CONTAINER_CERTS}/configmaps/etcd-all-bundles/server-ca-bundle.crt \
    --client-cert-auth=true \
    --peer-cert-file=${CONTAINER_CERTS}/secrets/etcd-all-certs/etcd-peer-${ETCD_NAME}.crt \
    --peer-key-file=${CONTAINER_CERTS}/secrets/etcd-all-certs/etcd-peer-${ETCD_NAME}.key \
    --peer-trusted-ca-file=${CONTAINER_CERTS}/configmaps/etcd-all-bundles/server-ca-bundle.crt \
    --peer-client-cert-auth=true"

# Step 3: Verify etcd is healthy
podman exec etcd-manual etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=${CONTAINER_CERTS}/configmaps/etcd-all-bundles/server-ca-bundle.crt \
  --cert=${CONTAINER_CERTS}/secrets/etcd-all-certs/etcd-serving-${ETCD_NAME}.crt \
  --key=${CONTAINER_CERTS}/secrets/etcd-all-certs/etcd-serving-${ETCD_NAME}.key
```

**Key findings from manual recovery (2026-10-05)**:

1. **SELinux is the critical blocker**: The cert files have `kubernetes_file_t` SELinux context. Without the `:z` flag on the podman volume mount, etcd gets `permission denied` when reading certs. The `:z` flag relabels the files to a shared container context.

2. **Host networking is required**: The etcd process needs to bind to the node's IP address (e.g., `192.168.40.26:2380`). Without `--network=host`, the container can't assign that address and fails with `bind: cannot assign requested address`.

3. **Cert path mapping**: On the host, certs are at `/etc/kubernetes/static-pod-resources/etcd-certs/`. Inside the etcd container, they appear at `/etc/kubernetes/static-pod-certs/`. The podman mount must map host path to container path.

4. **`initial-cluster-state=new`** creates a fresh single-member cluster. This is correct for recovery from a snapshot restore. The etcd operator will scale up additional members once it detects the healthy single member.

5. **Do NOT remove the manual podman container** until the kubelet-managed etcd pod has started and taken over. Removing it releases ports 2379/2380, and if the kubelet hasn't started its own etcd pod yet, the API goes down again.

6. **The kubelet eventually starts the etcd static pod** on its own after ~15-20 minutes of retrying. The manual podman container is a bridge to get the API up faster. Once the kubelet-managed pod is running (check with `crictl ps | grep etcd`), the manual container can be safely removed.

7. **Independently restored snapshots on non-recovery nodes cause cluster ID mismatches**. If you restore the same snapshot on multiple nodes using `etcdutl snapshot restore` with different `--initial-cluster` values, each node gets a different cluster ID and they cannot form a cluster together. The correct approach is to let the etcd operator add members to the existing cluster, not to independently restore on each node.

### Issue: SSH Host Key Changes After Node Reboot

**Symptom**: `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` when SSHing to a node after it has been rebooted or re-provisioned.

**Fix**: Remove the old host key and re-add:
```bash
ssh-keygen -f ~/.ssh/known_hosts -R '<node_name>'
ssh core@<node_name>  # Re-add the new host key
```

### Issue: Backup Files Have Root-Only Permissions

**Symptom**: `scp` fails with `Permission denied` when copying backup files from a control plane node.

**Fix**: Use `sudo cat` to read the files and pipe to local:
```bash
ssh core@<node> 'sudo cat /home/core/assets/backup/snapshot_*.db' > ~/local/backup.db
```

### Recovering a Degraded Single-Member etcd Cluster (verified working, 2026-10-05)

After the restore test left the luke cluster with a single-member etcd (control01 only), the following procedure was used to recover all 3 members and clear the etcd operator's DEGRADED status:

**Step 1**: Wipe stale `/var/lib/etcd` data on the non-recovery nodes (if they have independently restored data with mismatched cluster IDs):
```bash
# On control02 and arbiter:
sudo rm -rf /var/lib/etcd && sudo mkdir -p /var/lib/etcd
```

**Step 2**: Restore the `etcd-pod.yaml` static pod manifest to `/etc/kubernetes/manifests/` on both nodes (if it was removed during the restore process):
```bash
# The manifest is typically backed up in /home/core/assets/manifests-stopped/
sudo cp /home/core/assets/manifests-stopped/etcd-pod.yaml /etc/kubernetes/manifests/
```

**Step 3**: Wait for the kubelet to start the etcd containers. The etcd process will detect the live cluster and match the cluster ID, then wait to be added as a member:
```bash
# Verify the etcd container is running and waiting:
sudo crictl ps | grep etcd
sudo crictl logs <etcd_container_id> | tail -5
# Expected output: "Live Cluster ID: [xxx], local: [xxx] ... member not found in member list"
```

**Step 4**: Manually add the missing members using `etcdctl` from the healthy node:
```bash
# From control01 (the healthy member), add each missing member:
oc exec -n openshift-etcd etcd-control01.syangsao.net -c etcd -- env -i \
  ETCDCTL_API=3 /usr/bin/etcdctl member add control02.syangsao.net \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
    --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-serving-control01.syangsao.net.crt \
    --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-serving-control01.syangsao.net.key \
    --peer-urls=https://<CONTROL02_IP>:2380

# Repeat for arbiter with its IP
```

**Step 5**: Verify all members are healthy:
```bash
oc exec -n openshift-etcd etcd-control01.syangsao.net -c etcd -- env -i \
  ETCDCTL_API=3 /usr/bin/etcdctl endpoint health \
    --endpoints=https://127.0.0.1:2379,https://<IP1>:2379,https://<IP2>:2379 \
    --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
    --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-serving-control01.syangsao.net.crt \
    --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-serving-control01.syangsao.net.key
```

**Step 6**: Fix the etcd operator's DEGRADED status (static pod registration):

After steps 1-5, the etcd data plane is healthy (3/3 members) but the operator may still show `DEGRADED=True` with errors like:
- `GuardControllerDegraded: [Missing operand on node <node>]`
- `MissingStaticPodControllerDegraded: static pod "etcd" ... didn't show up, waited: 3m0s`

This happens because the kubelet started the etcd containers locally but failed to register the pod objects in the API. The fix is to **restart the kubelet** on the affected nodes to force a clean static pod registration cycle:
```bash
# On each node where the etcd pod isn't registered in the API:
sudo systemctl restart kubelet
```

After the kubelet restarts, it re-processes the static pod manifests and creates the pod objects in the API. The operator then detects the pods and clears the DEGRADED status.

> **Warning**: Do NOT use `oc patch etcd cluster` with `forceRedeploymentReason` to fix this. On a single-member or degraded cluster, the force redeployment can trigger the operator to restart etcd on the only healthy node, taking down the API entirely. The kubelet restart is safe because it doesn't touch the running etcd process — it just re-registers the pod object.

**Step 7**: Verify final state:
```bash
# All 3 etcd pods should be registered and running:
oc get pods -n openshift-etcd -l k8s-app=etcd
# Expected:
#   etcd-control01.syangsao.net   5/5   Running
#   etcd-control02.syangsao.net   5/5   Running
#   etcd-arbiter.syangsao.net     5/5   Running

# Operator should show DEGRADED=False:
oc get co etcd
```

**Result** (verified on luke cluster, 2026-10-05): All 3 etcd members healthy (~9ms), all pods registered in API, etcd operator DEGRADED=False. The operator showed PROGRESSING=True as it rolled out a new etcd revision — this is normal post-recovery behavior and completes on its own.

## Quick Reference

| Action | Command |
|--------|---------|
| Take etcd backup | `oc debug --as-root node/<node>` → `chroot /host` → `/usr/local/bin/cluster-backup.sh /home/core/assets/backup` |
| Restore from backup | `sudo -E /usr/local/bin/cluster-restore.sh /home/core/assets/backup` |
| Disable etcd on a node | `sudo -E /usr/local/bin/disable-etcd.sh` |
| Restore quorum (no backup) | `sudo -E /usr/local/bin/quorum-restore.sh` |
| Check etcd health | `oc rsh -n openshift-etcd <pod> etcdctl endpoint health` |
| List etcd members | `oc rsh -n openshift-etcd <pod> etcdctl member list -w table` |
| Force etcd redeployment | `oc patch etcd cluster -p='{"spec":{"forceRedeploymentReason":"recovery-'"$(date +%s)"'"}}' --type=merge` |
| Turn off quorum guard | `oc patch etcd/cluster --type=merge -p '{"spec":{"unsupportedConfigOverrides":{"useUnsupportedUnsafeNonHANonProductionUnstableEtcd":true}}}'` |
| Turn on quorum guard | `oc patch etcd/cluster --type=merge -p '{"spec":{"unsupportedConfigOverrides":null}}'` |
| Wait for cluster stability | `oc adm wait-for-stable-cluster` |
