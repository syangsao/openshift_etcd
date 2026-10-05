#!/bin/bash
# etcd-restore-test.sh - Simulate etcd failure and test restore procedure
# Usage: ./etcd-restore-test.sh <recovery_node> <non_recovery_nodes...>
#
# WARNING: This is DESTRUCTIVE. Only use on non-production clusters.
# It simulates etcd failure on non-recovery nodes, then you manually
# run the restore procedure (see README.md Part 2).
#
# Prerequisites:
#   - oc CLI with cluster-admin access
#   - SSH access to ALL control plane nodes (user: core)
#   - A recent etcd backup in /home/core/assets/backup on the recovery node

set -euo pipefail

RECOVERY_NODE="${1:?Usage: $0 <recovery_node> <non_recovery_nodes...>}"
shift
NON_RECOVERY_NODES=("$@")

echo "=== OpenShift etcd Restore Test (DESTRUCTIVE) ==="
echo "Recovery node: ${RECOVERY_NODE}"
echo "Non-recovery nodes: ${NON_RECOVERY_NODES[*]}"
echo ""
echo "WARNING: This will simulate etcd failure on non-recovery nodes."
echo "You must have SSH access to ALL control plane nodes."
echo "A backup must exist in /home/core/assets/backup on ${RECOVERY_NODE}."
echo ""
read -p "Continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

# Step 1: Verify backup exists on recovery node
echo "[1/4] Verifying backup on ${RECOVERY_NODE}..."
ssh "core@${RECOVERY_NODE}" 'ls -lh /home/core/assets/backup/' || {
    echo "ERROR: No backup found in /home/core/assets/backup on ${RECOVERY_NODE}"
    exit 1
}

# Step 2: Establish SSH connections (verify)
echo "[2/4] Verifying SSH access to all nodes..."
for NODE in "$RECOVERY_NODE" "${NON_RECOVERY_NODES[@]}"; do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "core@${NODE}" 'hostname' &>/dev/null; then
        echo "  ${NODE}: OK"
    else
        echo "  ${NODE}: FAILED - you must fix SSH access before continuing"
        exit 1
    fi
done

# Step 3: Simulate etcd failure on non-recovery nodes
echo "[3/4] Simulating etcd failure on non-recovery nodes..."
for NODE in "${NON_RECOVERY_NODES[@]}"; do
    echo "  Disabling etcd and kubelet on ${NODE}..."
    ssh "core@${NODE}" 'sudo /usr/local/bin/disable-etcd.sh && sudo rm -rf /var/lib/etcd && sudo systemctl disable kubelet.service --now'
done

# Step 4: Verify non-recovery nodes are NotReady
echo "[4/4] Verifying node status..."
sleep 10
oc get nodes

echo ""
echo "=== Failure simulation complete ==="
echo ""
echo "Next steps (manual):"
echo "  1. On ${RECOVERY_NODE}, run the restore:"
echo "     ssh core@${RECOVERY_NODE}"
echo "     sudo -E /usr/local/bin/cluster-restore.sh /home/core/assets/backup"
echo ""
echo "  2. Monitor recovery:"
echo "     oc adm wait-for-stable-cluster"
echo ""
echo "  3. Turn off quorum guard when API responds:"
echo "     oc patch etcd/cluster --type=merge -p '{\"spec\":{\"unsupportedConfigOverrides\":{\"useUnsupportedUnsafeNonHANonProductionUnstableEtcd\":true}}}'"
echo ""
echo "  4. Re-enable kubelet on non-recovery nodes:"
for NODE in "${NON_RECOVERY_NODES[@]}"; do
    echo "     ssh core@${NODE} 'sudo systemctl enable kubelet.service --now'"
done
echo ""
echo "  5. Turn quorum guard back on:"
echo "     oc patch etcd/cluster --type=merge -p '{\"spec\":{\"unsupportedConfigOverrides\":null}}'"
echo ""
echo "See README.md Part 2 for full details."
