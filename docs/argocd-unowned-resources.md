# Argo CD Unowned Resources

DriftHound can report Kubernetes objects that exist in a cluster (for example AKS) but that no Argo CD Application owns. These are objects someone created by hand with `kubectl apply` or `helm install`, or objects left behind when an Application was deleted without pruning. The report appears next to your other drift: an environment with unowned objects shows `DRIFT`.

## How it works

1. The CLI asks `kubectl` which kinds the cluster serves, then lists each kind once.
2. It reads the Argo CD Applications.
3. It decides for each object whether Argo CD owns it, and reports the ones it does not.
4. The server applies the ignore rules and sets the final status.

Everything is collected and compared on the machine that runs the CLI. DriftHound never holds cluster credentials, and it only receives the unowned objects.

## What counts as owned

The CLI reports only **roots**: objects that nothing else owns. It checks each object in this order. The first rule that matches wins.

1. **It has an owner.** An object with `ownerReferences` (a ReplicaSet, a Pod of a Deployment, and so on) is never reported itself. The owner is judged instead, so a hand-made Deployment is reported once, with `dependents` in its metadata counting the objects below it. If the owner is not in the inventory (for example a mirror Pod owned by a Node), the object still counts as owned.
2. **Argo CD tracks it.** By default (`--tracking-method=annotation`, the Argo CD 3 default) the object carries the `argocd.argoproj.io/tracking-id` annotation, which has the form `<app>:<group>/<kind>:<namespace>/<name>`. The CLI applies the same checks Argo CD does:
   - the annotation must parse, and it must point at the object itself (an annotation copied by another tool does not count);
   - the application name must belong to a known Application, so leftovers of a deleted Application are reported;
   - with `--argocd-installation-id`, the `argocd.argoproj.io/installation-id` annotation must match.

   With `--tracking-method=label`, the label named by `--instance-label-key` must hold the name of a known Application. In annotation modes the label is ignored on purpose: most Helm charts set `app.kubernetes.io/instance` to the release name, which would hide releases installed by hand.
3. **An Application lists it.** An Application that deploys to this cluster lists the object in `status.resources`. This catches objects Argo CD manages but does not mark.
4. **It is an Application's destination namespace.** Namespaces created with `CreateNamespace=true` are not tracked, so a Namespace equal to an Application's `spec.destination.namespace` counts as owned. A namespace that no Application deploys to is reported, even if it holds Argo CD objects.
5. **It belongs to the Argo CD control plane.** Everything in the namespaces given by `--argocd-namespace` (default `argocd`), and those namespaces themselves, is skipped. Applications, ApplicationSets and AppProjects in them are still reported, so a hand-made bootstrap Application shows up.
6. **The platform manages it** (skipped unless `--include-platform-managed`):
   - label `kubernetes.azure.com/managedby=aks`;
   - any `addonmanager.kubernetes.io/mode` label;
   - label `kubernetes.io/bootstrapping=rbac-defaults` (the default ClusterRoles and ClusterRoleBindings);
   - a Helm release name that starts with `aks-managed`;
   - anything inside a namespace that carries one of the first two labels.
7. **It is derived storage.** A PersistentVolume that was provisioned for a claim, and a PersistentVolumeClaim that a StatefulSet creates from its `volumeClaimTemplates`.

Anything else is reported.

### Helm

`app.kubernetes.io/managed-by: Helm` means nothing by itself: charts template it, so objects Argo CD renders from a chart carry it too. An object without a valid Argo CD marker is unowned whatever labels it has. For objects created with `helm install`, the metadata also holds `helm_release`, `helm_release_namespace` and `helm_chart` (from the `meta.helm.sh/*` annotations that `helm install` and `helm upgrade` add), and the check output groups the unowned objects by release. Those annotations are not added by `helm template`, which Argo CD uses.

### Kinds that are not listed

The CLI never lists churn and always-owned kinds: Events, Endpoints, EndpointSlices, Leases, Nodes, ControllerRevisions, APIServices, review kinds, CertificateSigningRequests, flow-control kinds, Kyverno and Cilium reports and identities, CertificateRequests, and the `metrics.k8s.io` groups. Secrets are skipped unless you pass `--include-secrets` (see Security). Add more with `--exclude-kind=<plural>[.<group>]`, the form `kubectl api-resources -o name` prints.

## Identifier format

Each object's identifier is `<group|core>/<Kind>/<namespace|_cluster>/<name>`:

| Object | Identifier |
|--------|------------|
| Deployment `web` in `shop` | `apps/Deployment/shop/web` |
| ConfigMap `settings` in `default` | `core/ConfigMap/default/settings` |
| Namespace `scratch` | `core/Namespace/_cluster/scratch` |
| ClusterRole `hand-made` | `rbac.authorization.k8s.io/ClusterRole/_cluster/hand-made` |

The cluster is not part of the identifier. It is stored as the row's `location` (from `--cluster-name`, else the context), so rules survive renaming a kubeconfig context. `scope` is the namespace, and is empty for cluster-scoped objects. `resource_type` is `Kind` for the core group and `Kind.group` otherwise. `core` cannot clash with an API group, because custom groups contain a dot, and `_cluster` cannot be a namespace name.

Other metadata fields: `api_version`, `uid`, `created_at`, `reason` (`untracked`, `unknown-application`, `not-self-referenced`, `installation-id-mismatch` or `invalid-tracking-id`), `tracking_id`, `managed_by`, `dependents`, `secret_type` and a few labels. When the metadata would pass 1,800 bytes, the CLI drops the labels, then the tracking id, and sets `truncated`.

## Built-in ignore list

The server ignores these by default. They are read-only, apply to the `argocd` source, and match without case. They are shown on the environment page and returned by the ignore rules API. `field` is `identifier` unless the row says `scope`.

| Pattern | What it covers |
|---------|----------------|
| `scope = kube-system`, `kube-public`, `kube-node-lease`, and their `core/Namespace/_cluster/<name>` objects | System namespaces and their contents |
| `core/Namespace/_cluster/default` | The `default` namespace object (not its contents) |
| `core/Service/default/kubernetes` | The API server Service |
| `core/ConfigMap/*/kube-root-ca.crt` | Per-namespace cluster CA |
| `core/ServiceAccount/*/default` | Per-namespace default ServiceAccount |
| `rbac.authorization.k8s.io/{ClusterRole,ClusterRoleBinding}/_cluster/system:*`, `.../{Role,RoleBinding}/*/system:*` | Kubernetes system RBAC (`system:` is reserved) |
| `scheduling.k8s.io/PriorityClass/_cluster/system-*` | Built-in PriorityClasses |
| `apiextensions.k8s.io/CustomResourceDefinition/_cluster/{applications,applicationsets,appprojects}.argoproj.io` | Argo CD CRDs |
| `argoproj.io/AppProject/*/default` | Argo CD's default AppProject |
| `rbac.authorization.k8s.io/{ClusterRole,ClusterRoleBinding}/_cluster/argocd-*` | Argo CD install RBAC (default names) |
| `gatekeeper-system`, `calico-system`, `tigera-operator`, `app-routing-system` namespaces; `scope = aks-istio-*` | AKS add-on namespaces and their contents |
| `*.gatekeeper.sh`, `*.projectcalico.org`, `*.tigera.io`, `*.kubernetes.azure.com` CRDs | AKS add-on CRDs |
| `templates.gatekeeper.sh/ConstraintTemplate/_cluster/k8sazure*`, `constraints.gatekeeper.sh/*/_cluster/azurepolicy-*` | Azure Policy objects |
| `StorageClass` `default`, `managed*`, `azurefile*`; `CSIDriver` `*.csi.azure.com` | AKS storage defaults |

Some of the AKS names (the add-on CRD suffixes, the Azure Policy object names, the StorageClass names and the Istio namespace pattern) come from documentation and memory and have not been checked against a live cluster. If a rule hides something it should not, tell the maintainers. A `scope` rule hides the contents of a namespace but not its Namespace object, which is why each system namespace has a second rule. There is deliberately no `scope=default` rule: hand-applied objects in `default` are exactly what this check should find.

## Your own ignore rules

Rules work as described in [Azure Unmanaged Resources](azure-unmanaged-resources.md#your-own-ignore-rules): `exact` or `glob` on `identifier`, `resource_type`, `name`, `scope` or `location`, per environment, matched without case.

| Pattern | Match | Effect |
|---------|-------|--------|
| `apps/Deployment/sandbox-*` | `glob` on `identifier` | Deployments named `sandbox-...` in any namespace |
| `sandbox` | `exact` on `scope` | Every object in the `sandbox` namespace |
| `*.example.com` | `glob` on `name` | Anything named `...example.com` |

In the web UI, admins get an **Ignore** button on each row (an exact rule on the identifier). Rules apply from the next check; stored checks are never rewritten. Case-only differences in RBAC names (two ClusterRoles that differ only in case) are stored as one row, because the server de-duplicates identifiers without case.

## Several Argo CD setups

- **Argo CD runs in the scanned cluster** (the default). The CLI reads Applications whose destination is `https://kubernetes.default.svc` or `in-cluster`. Pass `--argocd-destination` to use other names.
- **Argo CD runs in a hub cluster.** Pass `--argocd-context=<hub context>` and `--argocd-destination=<server URL or name of the scanned cluster>`. The destination is required: an ApplicationSet that deploys the same manifests to many clusters would otherwise make one cluster's Applications mark another cluster's same-named objects as owned.
- **Several Argo CD control planes in one cluster.** List every namespace with `--argocd-namespace`. Applications outside the listed namespaces are named `<namespace>_<name>`, as Argo CD does for apps in any namespace.
- **Several installations that share the cluster.** If each installation has its own `installationID`, run the CLI once per installation with `--argocd-installation-id`, and use one environment key per installation.

Applications are always read from all namespaces. If no Application deploys to the scanned cluster, the CLI fails and lists the destinations it saw, which usually means the wrong context.

## Security

- No cluster credentials are sent to DriftHound. The CLI lists objects through a fixed `jsonpath` projection (names, labels used for ownership, a few annotations, and a Secret's type). It never reads `.data`, `.stringData` or whole annotations, so it holds no secret data even though `kubectl apply` stores a copy of each manifest in `last-applied-configuration`.
- Secrets are skipped by default. A client that can list Secrets can read all of them, so grant RBAC without `secrets` unless you need `--include-secrets`. Most Secrets are generated (Helm release storage, service account tokens, certificates), so listing them is mostly noise.
- Give the CLI a read-only identity.
- The unowned list reveals namespaces and object names. In the web UI it is shown only to users who may see plan output (`PLAN_OUTPUT_MIN_ROLE`, see [Configuration](configuration.md#plan_output_min_role)); in the API only `read_plans` and `write` tokens receive it.

## Limits

- At most 5,000 objects per check. The CLI sends the first 5,000 in identifier order and states in the check output how many it dropped. The server applies built-in and user rules after that cut, so the dropped tail may contain rows the server would have ignored. Narrow the scan with `--exclude-kind` rather than relying on the cut.
- The check output lists the first 200 identifiers. The web UI shows up to 1,000 rows per list; use the API for more.
- `kubectl` holds one kind's full list in memory while it prints. Peak memory is roughly the largest kind times `--concurrency`. Use `--concurrency=1` in memory-tight jobs. A typical cluster with 150 to 250 kinds should take a few tens of seconds (an estimate, not measured).
- Dashboard charts count checks from all sources. Use **Exclude from Metrics** to keep these environments out of the charts.

## RBAC

The CLI needs `get` and `list` on what it scans, plus `list` on `applications.argoproj.io`. Discovery (`kubectl api-resources`) needs nothing extra.

**Option A: simple.** Read everything. Note that this also allows reading Secrets, even though the CLI never lists them.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: drifthound-reader
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get", "list"]
```

**Option B: hardened (recommended).** RBAC has no deny rules, and `apiGroups: ["*"]` includes the core group, so list the groups and resources explicitly and leave out `secrets`. Add more groups for the CRDs you run; the CLI's forbidden-kinds error names every kind it could not read.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: drifthound-reader
rules:
  - apiGroups: [""]
    resources: [configmaps, namespaces, persistentvolumeclaims, persistentvolumes, pods, serviceaccounts, services]
    verbs: [get, list]
  - apiGroups: [apps, batch, networking.k8s.io, policy, autoscaling]
    resources: ["*"]
    verbs: [get, list]
  - apiGroups: [rbac.authorization.k8s.io, apiextensions.k8s.io, storage.k8s.io, scheduling.k8s.io, admissionregistration.k8s.io]
    resources: ["*"]
    verbs: [get, list]
  - apiGroups: [argoproj.io]
    resources: [applications, applicationsets, appprojects]
    verbs: [get, list]
```

Bind it to the CI identity or, for the in-cluster job below, to its service account:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: drifthound-reader
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: drifthound-reader }
subjects:
  - { kind: ServiceAccount, name: drifthound, namespace: drifthound }
```

## Running it in CI

### GitHub Actions

The action versions and the `kubelogin` step below were not checked against the current action READMEs; confirm them before use.

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  argocd-unowned:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: azure/setup-kubectl@v4
      - name: Get cluster credentials
        run: |
          az aks get-credentials -g RG -n CLUSTER --overwrite-existing
          # Entra ID clusters only:
          # kubelogin convert-kubeconfig -l azurecli
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
      - name: Report unowned resources
        run: |
          curl -fsSL https://raw.githubusercontent.com/drifthoundhq/drifthound/main/bin/drifthound-cli -o drifthound
          chmod +x drifthound
          ./drifthound --tool=argocd \
            --project=platform \
            --environment=prod-aks-argocd \
            --context=CLUSTER \
            --token=${{ secrets.DRIFTHOUND_TOKEN }} \
            --api-url=${{ vars.DRIFTHOUND_URL }}
```

### In-cluster CronJob

The DriftHound image has Ruby and the CLI at `/usr/local/bin/drifthound`, but no `kubectl`. An init container copies a `kubectl` binary onto a shared volume. The init image below is a placeholder: use an image you trust that contains `kubectl`. The CLI reads no environment variables, and Kubernetes expands `$(VAR)` in `args`, so the token comes from a Secret through `env`.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: drifthound
  namespace: drifthound
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: drifthound-argocd
  namespace: drifthound
spec:
  schedule: "17 */6 * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: drifthound
          restartPolicy: Never
          volumes:
            - name: bin
              emptyDir: {}
          initContainers:
            - name: kubectl
              image: example.registry/kubectl:TAG   # placeholder: an image that contains kubectl
              command: ["cp", "/path/to/kubectl", "/shared/kubectl"]
              volumeMounts:
                - { name: bin, mountPath: /shared }
          containers:
            - name: drifthound
              image: ghcr.io/drifthoundhq/drifthound:TAG
              command: ["/usr/local/bin/drifthound"]
              args:
                - --tool=argocd
                - --kubectl=/shared/kubectl
                - --cluster-name=prod-aks
                - --project=platform
                - --environment=prod-aks-argocd
                - --concurrency=1
                - --token=$(DRIFTHOUND_TOKEN)
                - --api-url=https://drifthound.example.com
              env:
                - name: DRIFTHOUND_TOKEN
                  valueFrom:
                    secretKeyRef: { name: drifthound-token, key: token }
              volumeMounts:
                - { name: bin, mountPath: /shared }
              resources:
                limits:
                  memory: 1Gi
```

The pod has no git binary, so repository and branch are not detected; pass `--repository` and `--branch` if you want them stored.

## Troubleshooting

**The check is `error`.** Read the check output. Typical causes: `kubectl` not found or not signed in, a kind the identity cannot read (the message lists the kinds; grant list access or skip them with `--exclude-kind`), or the Argo CD CRDs are missing in the context.

**"no Argo CD Application deploys to ...".** The context or destination is wrong. The message lists the destinations the Applications use. Pass the matching `--argocd-destination`, or `--context` for the right cluster.

**"this Argo CD may use label tracking".** Nothing in the cluster has a tracking annotation, but objects carry the instance label of known Applications. Argo CD 2.x tracks by label: pass `--tracking-method=label` (and `--instance-label-key` if you changed it).

**Everything is reported.** The tracking method or the installation ID probably does not match Argo CD's settings.

**Discovery reports errors for `metrics.k8s.io`.** A failing metrics server is tolerated and noted in the output. A failure in any other API group stops the check.

**The status flips between runs.** Two sources or two clusters share one environment key. Use one key per source and per cluster.

## Not checked against a live cluster

This feature was built without access to a cluster. These details come from the Argo CD, kubectl and Kubernetes documentation and source, and should be confirmed on a real cluster before you rely on them: that `kubectl get -o jsonpath` fills in each item's `apiVersion` and `kind` (the CLI fails with a clear error if it does not), the exact stderr text of a partial discovery failure, a forbidden listing and a removed kind, whether synced CRDs carry a tracking marker, the Kyverno and Cilium resource names in the skip list, and the AKS names listed above.
