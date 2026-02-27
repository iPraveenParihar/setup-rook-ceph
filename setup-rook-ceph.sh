#!/usr/bin/env bash

# Copyright 2025 The Rook Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script is used by the setup-rook-ceph-cluster composite GitHub Action
# to deploy a minimal Rook+Ceph cluster on Ubuntu GitHub runners.
# The disk preparation and deployment logic is adapted from
# rook/rook tests/scripts/github-action-helper.sh.

set -xeEo pipefail

#############
# VARIABLES #
#############

ROOK_BASE_URL="https://raw.githubusercontent.com/rook/rook"
MANIFESTS_DIR="${RUNNER_TEMP:-/tmp}/rook-manifests"

# Architecture detection
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  ARCH_SUFFIX="arm64"
else
  ARCH_SUFFIX="amd64"
fi

#############
# FUNCTIONS #
#############

# Creates a 75GB iSCSI disk for use as an OSD when no extra block device is
# available. Adapted from rook/rook tests/scripts/github-action-helper.sh.
function create_extra_disk() {
  sudo apt install -y targetcli-fb open-iscsi
  truncate -s 75G ~/iscsi-disk.img
  sudo targetcli /backstores/fileio create disk1 ~/iscsi-disk.img 75G
  local target_iqn=iqn.2025-01.target.local:disk1
  sudo targetcli /iscsi create ${target_iqn}
  sudo targetcli /iscsi/${target_iqn}/tpg1/luns create /backstores/fileio/disk1
  local init_iqn=iqn.2025-01.initiator.local
  echo "InitiatorName=${init_iqn}" | sudo tee /etc/iscsi/initiatorname.iscsi >/dev/null
  sudo targetcli /iscsi/${target_iqn}/tpg1/acls create ${init_iqn}
  sudo targetcli /iscsi/${target_iqn}/tpg1/acls/${init_iqn} create tpg_lun_or_backstore=lun0 mapped_lun=0
  sudo iscsiadm -m discovery -t sendtargets -p 127.0.0.1
  sudo iscsiadm -m node --login
}

# Finds an available extra block device on the runner, or creates one via
# iSCSI if none exists. Adapted from rook/rook tests/scripts/github-action-helper.sh.
function find_extra_block_dev() {
  # shellcheck disable=SC2005
  echo "$(sudo lsblk)" >/dev/stderr
  boot_dev="$(sudo lsblk --noheading --list --output MOUNTPOINT,PKNAME | grep boot | awk '{print $2}')"
  echo "  == find_extra_block_dev(): boot_dev='$boot_dev'" >/dev/stderr
  # --nodeps ignores partitions
  extra_dev="$(sudo lsblk --noheading --list --nodeps --output KNAME | grep -Ev "($boot_dev|loop|nbd)" | head -1)"
  if [ -z "$extra_dev" ]; then
    create_extra_disk >/dev/stderr
    extra_dev="$(sudo lsblk --noheading --list --nodeps --output KNAME | grep -Ev "($boot_dev|loop|nbd)" | head -1)"
  fi
  echo "  == find_extra_block_dev(): extra_dev='$extra_dev'" >/dev/stderr
  echo "$extra_dev"
}

function block_dev() {
  declare -g DEFAULT_BLOCK_DEV
  : "${DEFAULT_BLOCK_DEV:=/dev/$(block_dev_basename)}"
  echo "$DEFAULT_BLOCK_DEV"
}

function block_dev_basename() {
  declare -g DEFAULT_BLOCK_DEV_BASENAME
  : "${DEFAULT_BLOCK_DEV_BASENAME:=$(find_extra_block_dev)}"
  echo "$DEFAULT_BLOCK_DEV_BASENAME"
}

# Prepares the local disk for OSD use. Adapted from
# rook/rook tests/scripts/github-action-helper.sh use_local_disk_for_integration_test().
function prepare_disk() {
  sudo apt purge snapd -y
  sudo udevadm control --log-priority=debug
  sudo swapoff --all --verbose

  # Create an extra disk if one doesn't exist
  : "$(block_dev)"
  sudo lsblk

  # If /mnt is not mounted, nothing more to do
  if ! mountpoint -q /mnt; then
    echo "ROOK_BLOCK_DEV_NAME=$(block_dev_basename)" >>"$GITHUB_ENV"
    return 0
  fi

  sudo umount /mnt
  sudo sed -i.bak '/\/mnt/d' /etc/fstab
  PARTITION="$(block_dev)1"
  sudo wipefs --all --force "$PARTITION"
  sudo dd if=/dev/zero of="${PARTITION}" bs=1M count=1
  sudo lsblk --bytes

  # Add udev rules to prevent permission resets on the disk
  # See: https://github.com/rook/rook/issues/7405
  echo "SUBSYSTEM==\"block\", ATTR{size}==\"29356032\", ACTION==\"add\", RUN+=\"/bin/chown 167:167 $PARTITION\"" \
    | sudo tee -a /etc/udev/rules.d/01-rook.rules
  # See: https://access.redhat.com/solutions/1465913
  echo "ACTION==\"add|change\", KERNEL==\"$(block_dev_basename)\", OPTIONS:=\"nowatch\"" \
    | sudo tee -a /etc/udev/rules.d/99-z-rook-nowatch.rules

  # Reload udev and settle to avoid partition reloads during OSD provisioning
  # See: https://github.com/rook/rook/issues/8975
  sudo udevadm control --reload-rules || true
  sudo udevadm trigger || true
  time sudo udevadm settle || true
  sudo partprobe || true
  sudo lsblk --noheadings --pairs "$(block_dev)" || true
  sudo sgdisk --print "$(block_dev)" || true
  sudo udevadm info --query=property "$(block_dev)" || true
  sudo lsblk --noheadings --pairs "${PARTITION}" || true
  journalctl -o short-precise --dmesg | tail -40 || true
  cat /etc/fstab || true

  # Export block device name for the deploy step
  echo "ROOK_BLOCK_DEV_NAME=$(block_dev_basename)" >>"$GITHUB_ENV"
}

# Downloads the required Rook deployment manifests from the rook/rook repo
# at the tag specified by ROOK_VERSION.
function download_manifests() {
  local version="${ROOK_VERSION:?ROOK_VERSION is required}"
  local base_url="${ROOK_BASE_URL}/${version}/deploy/examples"

  mkdir -p "${MANIFESTS_DIR}"

  local manifests=(
    crds.yaml
    common.yaml
    operator.yaml
    csi-operator.yaml
    cluster-test.yaml
    toolbox.yaml
    pool-test.yaml
    filesystem-test.yaml
  )

  echo "Downloading Rook ${version} manifests from rook/rook..."
  for manifest in "${manifests[@]}"; do
    echo "  Downloading ${manifest}..."
    curl -sSfL "${base_url}/${manifest}" -o "${MANIFESTS_DIR}/${manifest}"
  done

  # Also download NFS RBAC (needed by create_cluster_prerequisites pattern)
  mkdir -p "${MANIFESTS_DIR}/csi/nfs"
  curl -sSfL "${base_url}/csi/nfs/rbac.yaml" -o "${MANIFESTS_DIR}/csi/nfs/rbac.yaml"

  echo "Manifests downloaded to ${MANIFESTS_DIR}"
  ls -la "${MANIFESTS_DIR}"
}

# Deploys the Rook operator, CSI operator, CephCluster, and toolbox.
# Uses environment variables set by action.yaml:
#   ROOK_VERSION, ROOK_IMAGE, CEPH_IMAGE, CEPH_CSI_IMAGE,
#   CEPH_CSI_OPERATOR_IMAGE, CLUSTER_NAMESPACE, ROOK_BLOCK_DEV_NAME
function deploy_cluster() {
  local rook_image="${ROOK_IMAGE}"

  # If rook-image was not explicitly set, derive it from rook-version
  if [ -z "${rook_image}" ]; then
    rook_image="docker.io/rook/ceph:${ROOK_VERSION}"
  fi

  cd "${MANIFESTS_DIR}"

  # Step 1: Apply CRDs and common resources (namespace, RBAC)
  kubectl create -f crds.yaml -f common.yaml

  # Step 2: Patch and deploy the Rook operator
  sed -i "s|image: docker.io/rook/ceph:.*|image: ${rook_image}|g" operator.yaml
  sed -i "s|ROOK_LOG_LEVEL:.*|ROOK_LOG_LEVEL: DEBUG|g" operator.yaml
  sed -i 's/.*ROOK_CSI_ENABLE_NFS:.*/  ROOK_CSI_ENABLE_NFS: \"true\"/g' operator.yaml

  # If a custom ceph-csi image is specified, set it in the operator ConfigMap
  if [ -n "${CEPH_CSI_IMAGE}" ]; then
    sed -i "s|# ROOK_CSI_CEPH_IMAGE:.*|ROOK_CSI_CEPH_IMAGE: \"${CEPH_CSI_IMAGE}\"|g" operator.yaml
  fi

  kubectl create -f operator.yaml

  # Step 3: Deploy the CSI operator
  if [ -n "${CEPH_CSI_OPERATOR_IMAGE}" ]; then
    sed -i "s|image: quay.io/cephcsi/ceph-csi-operator:.*|image: ${CEPH_CSI_OPERATOR_IMAGE}|g" csi-operator.yaml
  fi
  kubectl create -f csi-operator.yaml

  # Step 4: Patch and deploy the CephCluster
  sed -i "s|image: .*ceph/ceph:.*|image: ${CEPH_IMAGE}|g" cluster-test.yaml

  if [ -n "${ROOK_BLOCK_DEV_NAME}" ]; then
    sed -i "s|#deviceFilter:|deviceFilter: ${ROOK_BLOCK_DEV_NAME}|g" cluster-test.yaml
  fi

  kubectl create -f cluster-test.yaml

  # Step 5: Deploy the toolbox with the same Ceph image
  sed -i "s|image: quay.io/ceph/ceph:.*|image: ${CEPH_IMAGE}|g" toolbox.yaml
  kubectl create -f toolbox.yaml

  # Step 6: Deploy CephBlockPool and CephFilesystem
  kubectl create -f pool-test.yaml
  kubectl create -f filesystem-test.yaml
}

# Waits for all cluster components to be ready. Adapted from
# rook/rook tests/scripts/github-action-helper.sh wait_for_prepare_pod() and
# tests/scripts/validate_cluster.sh.
function wait_for_cluster() {
  local ns="${CLUSTER_NAMESPACE:-rook-ceph}"
  local get_pod_cmd=(kubectl --namespace "$ns" get pod --no-headers)

  # Wait for the Rook operator deployment to roll out
  echo "Waiting for Rook operator to be ready..."
  kubectl -n "$ns" rollout status deployment/rook-ceph-operator --timeout=300s

  # Wait for mon.a to be created (up to 600s)
  # Most of this time is waiting for the detect version job to pull the ceph image
  echo "Waiting for mon.a to be created..."
  local timeout=600
  local start_time="${SECONDS}"
  while [[ $((SECONDS - start_time)) -lt $timeout ]]; do
    pod="$("${get_pod_cmd[@]}" --selector=app=rook-ceph-mon \
      --output custom-columns=NAME:.metadata.name,PHASE:status.phase 2>/dev/null || true)"
    if echo "$pod" | grep -q 'rook-ceph-mon-a'; then break; fi
    echo "  waiting for mon.a..."
    sleep 5
  done

  # Wait for OSD prepare pod to start (up to 450s)
  echo "Waiting for OSD prepare pod..."
  timeout=450
  start_time="${SECONDS}"
  while [[ $((SECONDS - start_time)) -lt $timeout ]]; do
    pod="$("${get_pod_cmd[@]}" --selector=app=rook-ceph-osd-prepare \
      --output custom-columns=NAME:.metadata.name,PHASE:status.phase 2>/dev/null \
      | awk 'FNR <= 1')"
    if echo "$pod" | grep -q 'Running\|Succeeded\|Failed'; then break; fi
    echo "  waiting for OSD prepare pod..."
    sleep 5
  done

  # Follow OSD prepare logs for visibility
  pod="$("${get_pod_cmd[@]}" --selector app=rook-ceph-osd-prepare --output name 2>/dev/null \
    | awk 'FNR <= 1')" || true
  if [ -n "$pod" ]; then
    kubectl --namespace "$ns" logs --follow "$pod" || true
  fi

  # Wait for at least 1 OSD daemon pod to be running (up to 120s)
  echo "Waiting for OSD daemon pod..."
  timeout=120
  start_time="${SECONDS}"
  while [[ $((SECONDS - start_time)) -lt $timeout ]]; do
    pod_count="$("${get_pod_cmd[@]}" --selector app=rook-ceph-osd \
      --output custom-columns=NAME:.metadata.name,PHASE:status.phase 2>/dev/null \
      | grep --count 'Running' || true)"
    if [ "$pod_count" -ge 1 ]; then break; fi
    echo "  waiting for OSD pod to be running..."
    sleep 5
  done

  # Wait for CSI pods (at least 3 running)
  echo "Waiting for CSI pods..."
  local csi_timeout=360
  start_time="${SECONDS}"
  while [[ $((SECONDS - start_time)) -lt $csi_timeout ]]; do
    csi_count="$(kubectl -n "$ns" get pods --field-selector=status.phase=Running --no-headers 2>/dev/null \
      | grep -c 'csi.' || true)"
    if [ "$csi_count" -ge 3 ]; then break; fi
    echo "  waiting for CSI pods to be ready (have ${csi_count}, need 3)..."
    sleep 5
  done

  # Wait for MDS pods (CephFilesystem)
  echo "Waiting for MDS pods..."
  local mds_timeout=300
  start_time="${SECONDS}"
  while [[ $((SECONDS - start_time)) -lt $mds_timeout ]]; do
    mds_count="$("${get_pod_cmd[@]}" --selector app=rook-ceph-mds \
      --output custom-columns=NAME:.metadata.name,PHASE:status.phase 2>/dev/null \
      | grep --count 'Running' || true)"
    if [ "$mds_count" -ge 1 ]; then
      echo "MDS pod is running!"
      break
    fi
    echo "  waiting for MDS pod to be running..."
    sleep 5
  done

  # Wait for toolbox deployment
  echo "Waiting for toolbox pod..."
  kubectl -n "$ns" rollout status deployment/rook-ceph-tools --timeout=120s || true

  # Validate Ceph health via the toolbox
  echo "Validating Ceph cluster health..."
  local validate_timeout=90
  start_time="${SECONDS}"
  local toolbox_pod
  toolbox_pod="$(kubectl get pod -l app=rook-ceph-tools -n "$ns" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$toolbox_pod" ]; then
    while [[ $((SECONDS - start_time)) -lt $validate_timeout ]]; do
      if kubectl -n "$ns" exec "$toolbox_pod" -- ceph -s --connect-timeout 10 2>/dev/null \
        | grep -q 'quorum'; then
        echo "Ceph cluster has quorum!"
        break
      fi
      echo "  waiting for Ceph quorum..."
      sleep 5
    done
  fi

  # Print final status for CI visibility
  echo ""
  echo "========================================="
  echo "  Rook Ceph Cluster - Final Status"
  echo "========================================="
  kubectl -n "$ns" get pods
  echo ""
  if [ -n "$toolbox_pod" ]; then
    kubectl -n "$ns" exec "$toolbox_pod" -- ceph -s --connect-timeout 10 || true
  fi
  kubectl -n "$ns" get cephcluster -o yaml || true
}

########
# MAIN #
########
FUNCTION="$1"
shift || true
"$FUNCTION" "$@"
