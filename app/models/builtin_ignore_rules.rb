# Server-side ignore rules that ship with DriftHound, keyed by check source.
# They are read-only and can be updated without users changing their pipelines.
class BuiltinIgnoreRules
  Rule = Data.define(:key, :field, :match_type, :pattern, :note) do
    include UnmanagedIgnoreMatching

    def ignore_reason
      "Built-in: #{note}"
    end
  end

  def self.azure_rule(key, pattern, note)
    Rule.new(key: key, field: "identifier", match_type: "glob", pattern: pattern, note: note)
  end
  private_class_method :azure_rule

  # Kubernetes object identifiers are core/Kind/<namespace|_cluster>/name or
  # group/Kind/<namespace|_cluster>/name. field is "scope" for namespace rules.
  def self.argo_rule(key, pattern, note, field: "identifier", match_type: "glob")
    Rule.new(key: key, field: field, match_type: match_type, pattern: pattern, note: note)
  end
  private_class_method :argo_rule

  def self.argo_namespace_rules(namespace, note)
    [
      argo_rule("ns-#{namespace}", namespace, "Objects in #{namespace}", field: "scope", match_type: "exact"),
      argo_rule("ns-#{namespace}-object", "core/Namespace/_cluster/#{namespace}", note, match_type: "exact")
    ]
  end
  private_class_method :argo_namespace_rules

  # Names from the upstream Argo CD install manifests (cluster install). Unverified: written from memory, not checked against a release.
  ARGOCD_CLUSTER_RBAC = %w[argocd-application-controller argocd-applicationset-controller argocd-server].freeze

  # Exact names of the StorageClasses AKS creates. Unverified: written from memory, not checked against a cluster.
  AKS_STORAGE_CLASSES = %w[
    default managed managed-csi managed-csi-premium managed-premium
    azurefile azurefile-csi azurefile-csi-premium azurefile-premium
  ].freeze

  REGISTRY = {
    "azure" => [
      azure_rule("network-watcher-rg", "/subscriptions/*/resourceGroups/NetworkWatcherRG", "Network Watcher resource group"),
      azure_rule("network-watcher-rg-contents", "/subscriptions/*/resourceGroups/NetworkWatcherRG/*", "Contents of NetworkWatcherRG"),
      azure_rule("network-watchers", "*/providers/Microsoft.Network/networkWatchers/NetworkWatcher_*", "Regional Network Watchers"),
      azure_rule("aks-node-rg", "/subscriptions/*/resourceGroups/MC_*", "AKS node resource group"),
      azure_rule("azure-monitor-default-rg", "/subscriptions/*/resourceGroups/DefaultResourceGroup-*", "Azure Monitor / Defender default resource group"),
      azure_rule("default-log-analytics", "*/providers/Microsoft.OperationalInsights/workspaces/DefaultWorkspace-*", "Default Log Analytics workspaces"),
      azure_rule("backup-restore-points", "/subscriptions/*/resourceGroups/AzureBackupRG_*", "Azure Backup restore point collections"),
      azure_rule("cloud-shell-storage", "/subscriptions/*/resourceGroups/cloud-shell-storage-*", "Cloud Shell storage"),
      azure_rule("sql-master-db", "*/providers/Microsoft.Sql/servers/*/databases/master", "SQL master database"),
      azure_rule("appinsights-smart-detection", "*/providers/microsoft.alertsmanagement/smartDetectorAlertRules/Failure Anomalies - *", "Application Insights smart detector rules"),
      azure_rule("appinsights-action-group", "*/providers/microsoft.insights/actiongroups/Application Insights Smart Detection", "Smart Detection action group")
    ].freeze,
    "argocd" => [
      *argo_namespace_rules("kube-system", "kube-system namespace"),
      *argo_namespace_rules("kube-public", "kube-public namespace"),
      *argo_namespace_rules("kube-node-lease", "kube-node-lease namespace"),
      argo_rule("ns-default-object", "core/Namespace/_cluster/default", "default namespace object (not its contents)", match_type: "exact"),
      argo_rule("svc-kubernetes", "core/Service/default/kubernetes", "API server Service", match_type: "exact"),
      argo_rule("kube-root-ca", "core/ConfigMap/*/kube-root-ca.crt", "Per-namespace cluster CA ConfigMap"),
      argo_rule("default-serviceaccount", "core/ServiceAccount/*/default", "Per-namespace default ServiceAccount"),
      argo_rule("system-clusterroles", "rbac.authorization.k8s.io/ClusterRole/_cluster/system:*", "Kubernetes system ClusterRoles"),
      argo_rule("system-clusterrolebindings", "rbac.authorization.k8s.io/ClusterRoleBinding/_cluster/system:*", "Kubernetes system ClusterRoleBindings"),
      argo_rule("system-roles", "rbac.authorization.k8s.io/Role/*/system:*", "Kubernetes system Roles"),
      argo_rule("system-rolebindings", "rbac.authorization.k8s.io/RoleBinding/*/system:*", "Kubernetes system RoleBindings"),
      argo_rule("system-priorityclasses", "scheduling.k8s.io/PriorityClass/_cluster/system-*", "Built-in PriorityClasses"),
      argo_rule("argocd-crd-applications", "apiextensions.k8s.io/CustomResourceDefinition/_cluster/applications.argoproj.io", "Argo CD CRD", match_type: "exact"),
      argo_rule("argocd-crd-applicationsets", "apiextensions.k8s.io/CustomResourceDefinition/_cluster/applicationsets.argoproj.io", "Argo CD CRD", match_type: "exact"),
      argo_rule("argocd-crd-appprojects", "apiextensions.k8s.io/CustomResourceDefinition/_cluster/appprojects.argoproj.io", "Argo CD CRD", match_type: "exact"),
      argo_rule("argocd-default-project", "argoproj.io/AppProject/*/default", "Argo CD's built-in default AppProject"),
      *ARGOCD_CLUSTER_RBAC.flat_map do |name|
        [
          argo_rule("argocd-clusterrole-#{name}", "rbac.authorization.k8s.io/ClusterRole/_cluster/#{name}", "Argo CD install ClusterRole", match_type: "exact"),
          argo_rule("argocd-clusterrolebinding-#{name}", "rbac.authorization.k8s.io/ClusterRoleBinding/_cluster/#{name}", "Argo CD install ClusterRoleBinding", match_type: "exact")
        ]
      end,
      argo_rule("aks-policy-templates", "templates.gatekeeper.sh/ConstraintTemplate/_cluster/k8sazure*", "Azure Policy constraint templates"),
      argo_rule("aks-policy-constraints", "constraints.gatekeeper.sh/*/_cluster/azurepolicy-*", "Azure Policy constraints"),
      *argo_namespace_rules("calico-system", "Calico namespace"),
      *argo_namespace_rules("tigera-operator", "Tigera operator namespace"),
      argo_rule("aks-calico-crds", "apiextensions.k8s.io/CustomResourceDefinition/_cluster/*.projectcalico.org", "Calico CRDs"),
      argo_rule("aks-tigera-crds", "apiextensions.k8s.io/CustomResourceDefinition/_cluster/*.tigera.io", "Tigera operator CRDs"),
      *argo_namespace_rules("app-routing-system", "AKS application routing namespace"),
      argo_rule("ns-aks-istio", "aks-istio-*", "Objects in AKS Istio add-on namespaces", field: "scope"),
      argo_rule("ns-aks-istio-object", "core/Namespace/_cluster/aks-istio-*", "AKS Istio add-on namespaces"),
      argo_rule("aks-crds", "apiextensions.k8s.io/CustomResourceDefinition/_cluster/*.kubernetes.azure.com", "AKS add-on CRDs"),
      *AKS_STORAGE_CLASSES.map do |name|
        argo_rule("aks-storageclass-#{name}", "storage.k8s.io/StorageClass/_cluster/#{name}", "AKS built-in StorageClass", match_type: "exact")
      end
    ].freeze
  }.freeze

  def self.for(source)
    REGISTRY.fetch(source.to_s, [])
  end
end
