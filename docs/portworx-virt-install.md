# Portworx + OpenShift Virt + MTV Install Reference

Reference commands for installing the platform components on a cluster. These
are **not automated** — they are copy-paste blocks for manual setup. The demo
scripts in `scripts/cluster-setup/` handle the post-install configuration
(RBAC, EA patches, license activation).

> **This repo does not automate these installs.** The demo assumes Portworx,
> OpenShift Virtualization, and MTV are already running on every spoke cluster.

---

## 1. Portworx (on ARO)

### Prerequisites

```bash
export CLUSTER_NAME='aro-spoke-1'
export TENANT_ID=$(az account show --query tenantId -o tsv)
```

### Create the namespace and Azure secret

```bash
oc create namespace portworx

oc create secret generic -n portworx px-azure \
    --from-literal=AZURE_TENANT_ID="$TENANT_ID" \
    --from-literal=AZURE_CLIENT_ID="$AZURE_CLIENT_ID" \
    --from-literal=AZURE_CLIENT_SECRET="$AZURE_CLIENT_SECRET"
```

### Enable user workload monitoring

```bash
cat << EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

### Install the Portworx operator

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: portworx-operatorgroup
  namespace: portworx
spec:
  targetNamespaces:
  - portworx
  upgradeStrategy: Default
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: portworx-certified
  namespace: portworx
spec:
  channel: stable
  installPlanApproval: Automatic
  name: portworx-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  startingCSV: portworx-operator.v26.2.1
EOF
```

### Apply the StorageCluster spec

```bash
oc apply -f APP_REG_portworx_enterprise.yaml
```

### Activate the license

```bash
oc exec -n portworx $(oc get pods -n portworx -l name=portworx \
    -o jsonpath='{.items[0].metadata.name}') -c portworx -- \
    /opt/pwx/bin/pxctl license activate saas --key "$PX_LICENSE_KEY"
```

---

## 2. Upgrade to Enterprise Portworx (EA builds)

> **Automated alternative:** `scripts/cluster-setup/01-install-portworx.sh`
> runs these patches across all spokes.

```bash
oc patch csv portworx-operator.v26.2.1 -n portworx --type=json \
    -p '[{"op":"replace","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image","value":"docker.io/portworx/px-operator:26.3.0-ea"}]'

oc patch storagecluster <PX_CLUSTER_NAME> -n portworx --type=merge \
    -p '{"spec": {"ocpDynamicPlugin": {"cacheAgentImage": "docker.io/portworx/px-cache-agent:1.1.0-ea", "pluginImage": "docker.io/portworx/portworx-dynamic-plugin:2.3.0-ea"}}}'

oc patch storagecluster <PX_CLUSTER_NAME> -n portworx --type=json \
    -p '[{"op": "add", "path": "/metadata/annotations/portworx.io~1service-type", "value": "portworx-api:LoadBalancer"}]'

oc create clusterrolebinding stork-cluster-admin \
    --clusterrole=cluster-admin \
    --serviceaccount=portworx:stork
```

---

## 3. OpenShift Virtualization

### Install the operator

```bash
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: "stable"
EOF
```

### Create the HyperConverged instance

```bash
cat << EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  annotations:
    deployOVS: 'false'
  namespace: openshift-cnv
spec:
  enableCommonBootImageImport: true
  virtualMachineOptions:
    disableFreePageReporting: false
    disableSerialConsoleLog: false
  higherWorkloadDensity:
    memoryOvercommitPercentage: 100
  liveMigrationConfig:
    allowAutoConverge: false
    allowPostCopy: false
    completionTimeoutPerGiB: 150
    parallelMigrationsPerCluster: 5
    parallelOutboundMigrationsPerNode: 2
    progressTimeout: 150
  certConfig:
    ca:
      duration: 48h0m0s
      renewBefore: 24h0m0s
    server:
      duration: 24h0m0s
      renewBefore: 12h0m0s
  enableApplicationAwareQuota: false
  applicationAwareConfig:
    allowApplicationAwareClusterResourceQuota: false
    vmiCalcConfigName: DedicatedVirtualResources
  featureGates:
    downwardMetrics: false
    disableMDevConfiguration: false
    deployKubeSecondaryDNS: false
    alignCPUs: false
    persistentReservation: false
  workloadUpdateStrategy:
    batchEvictionInterval: 1m0s
    batchEvictionSize: 10
    workloadUpdateMethods:
      - LiveMigrate
  deployVmConsoleProxy: false
  uninstallStrategy: BlockUninstallIfWorkloadsExist
  resourceRequirements:
    vmiCPUAllocationRatio: 10
EOF
```

---

## 4. Migration Toolkit for Virtualization (MTV)

### Install the operator

```bash
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-mtv-og
  namespace: openshift-mtv
spec:
  targetNamespaces:
  - openshift-mtv
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mtv-operator
  namespace: openshift-mtv
spec:
  channel: release-v2.12
  installPlanApproval: Automatic
  name: mtv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### Create the ForkliftController

```bash
cat << EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: ForkliftController
metadata:
  name: forklift-controller
  namespace: openshift-mtv
spec:
  feature_ui_plugin: "true"
  feature_validation: "true"
  feature_volume_populator: "true"
EOF
```
