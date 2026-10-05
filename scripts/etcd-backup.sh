#!/bin/bash
# etcd-backup.sh - Take an etcd backup from an OpenShift control plane node
# Usage: ./etcd-backup.sh <node_name> [output_dir]
#
# Prerequisites:
#   - oc CLI with cluster-admin access
#   - SSH access to the control plane node (user: core)
#   - No cluster-wide proxy (or set HTTP_PROXY/HTTPS_PROXY/NO_PROXY)

set -euo pipefail

NODE="${1:?Usage: $0 <node_name> [output_dir]}"
OUTPUT_DIR="${2:-~/etcd-backup/$(date +%Y%m%d)}"

echo "=== OpenShift etcd Backup ==="
echo "Node: ${NODE}"
echo "Output: ${OUTPUT_DIR}"
echo ""

# Step 1: Check proxy configuration
echo "[1/6] Checking proxy configuration..."
PROXY=$(oc get proxy cluster -o jsonpath='{.spec.httpProxy}' 2>/dev/null || echo "")
if [[ -n "$PROXY" ]]; then
    echo "  WARNING: Cluster-wide proxy is enabled."
    echo "  You will need to export HTTP_PROXY, HTTPS_PROXY, NO_PROXY in the debug shell."
fi

# Step 2: Create local output directory
echo "[2/6] Creating local output directory..."
mkdir -p "$OUTPUT_DIR"

# Step 3: Run backup on the control plane node
echo "[3/6] Running cluster-backup.sh on ${NODE}..."
oc debug --as-root "node/${NODE}" -q -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# Step 4: List backup files on the node
echo ""
echo "[4/6] Backup files on ${NODE}:"
ssh "core@${NODE}" 'ls -lh /home/core/assets/backup/'

# Step 5: Copy backup files to local machine
echo "[5/6] Copying backup files to ${OUTPUT_DIR}..."
SNAPFILE=$(ssh "core@${NODE}" 'ls /home/core/assets/backup/snapshot_*.db | tail -1' | xargs basename)
STATICFILE=$(ssh "core@${NODE}" 'ls /home/core/assets/backup/static_kuberesources_*.tar.gz | tail -1' | xargs basename)

echo "  Copying ${SNAPFILE}..."
ssh "core@${NODE}" "sudo cat /home/core/assets/backup/${SNAPFILE}" > "${OUTPUT_DIR}/${SNAPFILE}"

echo "  Copying ${STATICFILE}..."
ssh "core@${NODE}" "sudo cat /home/core/assets/backup/${STATICFILE}" > "${OUTPUT_DIR}/${STATICFILE}"

# Step 6: Verify
echo "[6/6] Verifying local backup files:"
ls -lh "${OUTPUT_DIR}/"
echo ""
echo "=== Backup complete ==="
echo "Files saved to: ${OUTPUT_DIR}"
echo ""
echo "IMPORTANT: Store these backups in a secure location outside the cluster."
