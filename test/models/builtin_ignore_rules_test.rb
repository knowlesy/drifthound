require "test_helper"

class BuiltinIgnoreRulesTest < ActiveSupport::TestCase
  SUB = "/subscriptions/00000000-0000-0000-0000-000000000000"

  def rule(key)
    BuiltinIgnoreRules.for("azure").find { |r| r.key == key } || flunk("no built-in rule #{key}")
  end

  def matches?(key, identifier)
    rule(key).matches?("identifier" => identifier)
  end

  test "for returns an empty list for unknown sources" do
    assert_equal [], BuiltinIgnoreRules.for("terraform")
    assert_equal [], BuiltinIgnoreRules.for(nil)
  end

  test "azure rules are glob rules on identifier with unique keys" do
    rules = BuiltinIgnoreRules.for("azure")
    assert_equal 11, rules.size
    assert_equal rules.map(&:key).uniq, rules.map(&:key)
    assert rules.all? { |r| r.field == "identifier" && r.match_type == "glob" }
  end

  test "ignore_reason names the note" do
    assert_equal "Built-in: Network Watcher resource group", rule("network-watcher-rg").ignore_reason
  end

  {
    "network-watcher-rg" => [ "/resourceGroups/NetworkWatcherRG", "/resourceGroups/NetworkWatcherRG2" ],
    "network-watcher-rg-contents" => [ "/resourceGroups/networkwatcherrg/providers/Microsoft.Network/networkWatchers/NetworkWatcher_westeurope", "/resourceGroups/app-NetworkWatcherRG/providers/x/y" ],
    "network-watchers" => [ "/resourceGroups/app/providers/Microsoft.Network/networkWatchers/NetworkWatcher_westeurope", "/resourceGroups/app/providers/Microsoft.Network/networkWatchers/my-watcher" ],
    "aks-node-rg" => [ "/resourceGroups/MC_rg_aks_westeurope/providers/Microsoft.Network/loadBalancers/kubernetes", "/resourceGroups/app-MC_rg" ],
    "azure-monitor-default-rg" => [ "/resourceGroups/DefaultResourceGroup-WEU", "/resourceGroups/app-DefaultResourceGroup-WEU" ],
    "default-log-analytics" => [ "/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/DefaultWorkspace-0000-WEU", "/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/my-workspace" ],
    "backup-restore-points" => [ "/resourceGroups/AzureBackupRG_westeurope_1", "/resourceGroups/MyAzureBackupRG_westeurope" ],
    "cloud-shell-storage" => [ "/resourceGroups/cloud-shell-storage-westeurope", "/resourceGroups/my-cloud-shell" ],
    "sql-master-db" => [ "/resourceGroups/rg/providers/Microsoft.Sql/servers/sql1/databases/master", "/resourceGroups/rg/providers/Microsoft.Sql/servers/sql1/databases/app" ],
    "appinsights-smart-detection" => [ "/resourceGroups/rg/providers/microsoft.alertsmanagement/smartDetectorAlertRules/Failure Anomalies - appi1", "/resourceGroups/rg/providers/microsoft.alertsmanagement/smartDetectorAlertRules/My alert" ],
    "appinsights-action-group" => [ "/resourceGroups/rg/providers/microsoft.insights/actiongroups/Application Insights Smart Detection", "/resourceGroups/rg/providers/microsoft.insights/actiongroups/oncall" ]
  }.each do |key, (hit, near_miss)|
    test "built-in #{key} matches a realistic id and not a near miss" do
      assert matches?(key, "#{SUB}#{hit}"), "expected #{key} to match #{hit}"
      assert_not matches?(key, "#{SUB}#{near_miss}"), "expected #{key} not to match #{near_miss}"
    end
  end

  test "built-ins do not hide ordinary resources" do
    id = "#{SUB}/resourceGroups/app/providers/Microsoft.Storage/storageAccounts/sa1"
    assert BuiltinIgnoreRules.for("azure").none? { |r| r.matches?("identifier" => id) }
  end

  # key => [attrs that must match, attrs that must not match]
  ARGO_CASES = {
    "ns-kube-system" => [ { "scope" => "kube-system" }, { "scope" => "kube-system-tools" } ],
    "ns-kube-system-object" => [ { "identifier" => "core/Namespace/_cluster/kube-system" }, { "identifier" => "core/Namespace/_cluster/kube-system-tools" } ],
    "ns-kube-public" => [ { "scope" => "kube-public" }, { "scope" => "kube-publicx" } ],
    "ns-kube-public-object" => [ { "identifier" => "core/Namespace/_cluster/kube-public" }, { "identifier" => "core/Namespace/_cluster/kube-publicx" } ],
    "ns-kube-node-lease" => [ { "scope" => "kube-node-lease" }, { "scope" => "kube-node-leasex" } ],
    "ns-kube-node-lease-object" => [ { "identifier" => "core/Namespace/_cluster/kube-node-lease" }, { "identifier" => "core/Namespace/_cluster/kube-node-leasex" } ],
    "ns-default-object" => [ { "identifier" => "core/Namespace/_cluster/default" }, { "identifier" => "core/ConfigMap/default/app" } ],
    "svc-kubernetes" => [ { "identifier" => "core/Service/default/kubernetes" }, { "identifier" => "core/Service/shop/kubernetes" } ],
    "kube-root-ca" => [ { "identifier" => "core/ConfigMap/shop/kube-root-ca.crt" }, { "identifier" => "core/ConfigMap/shop/kube-root-ca.crt.bak" } ],
    "default-serviceaccount" => [ { "identifier" => "core/ServiceAccount/shop/default" }, { "identifier" => "core/ServiceAccount/shop/default-runner" } ],
    "system-clusterroles" => [ { "identifier" => "rbac.authorization.k8s.io/ClusterRole/_cluster/system:foo" }, { "identifier" => "rbac.authorization.k8s.io/ClusterRole/_cluster/systemx:foo" } ],
    "system-clusterrolebindings" => [ { "identifier" => "rbac.authorization.k8s.io/ClusterRoleBinding/_cluster/system:foo" }, { "identifier" => "rbac.authorization.k8s.io/ClusterRoleBinding/_cluster/hand-made" } ],
    "system-roles" => [ { "identifier" => "rbac.authorization.k8s.io/Role/kube-system/system:leader-locking" }, { "identifier" => "rbac.authorization.k8s.io/Role/shop/app:system" } ],
    "system-rolebindings" => [ { "identifier" => "rbac.authorization.k8s.io/RoleBinding/kube-system/system:leader-locking" }, { "identifier" => "rbac.authorization.k8s.io/RoleBinding/shop/app:system" } ],
    "system-priorityclasses" => [ { "identifier" => "scheduling.k8s.io/PriorityClass/_cluster/system-cluster-critical" }, { "identifier" => "scheduling.k8s.io/PriorityClass/_cluster/high" } ],
    "argocd-crd-applications" => [ { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/applications.argoproj.io" }, { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/rollouts.argoproj.io" } ],
    "argocd-crd-applicationsets" => [ { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/applicationsets.argoproj.io" }, { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/rollouts.argoproj.io" } ],
    "argocd-crd-appprojects" => [ { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/appprojects.argoproj.io" }, { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/rollouts.argoproj.io" } ],
    "argocd-default-project" => [ { "identifier" => "argoproj.io/AppProject/argocd/default" }, { "identifier" => "argoproj.io/AppProject/argocd/default-team" } ],
    "argocd-clusterroles" => [ { "identifier" => "rbac.authorization.k8s.io/ClusterRole/_cluster/argocd-server" }, { "identifier" => "rbac.authorization.k8s.io/ClusterRole/_cluster/my-argocd-x" } ],
    "argocd-clusterrolebindings" => [ { "identifier" => "rbac.authorization.k8s.io/ClusterRoleBinding/_cluster/argocd-server" }, { "identifier" => "rbac.authorization.k8s.io/ClusterRoleBinding/_cluster/my-argocd-x" } ],
    "ns-gatekeeper-system" => [ { "scope" => "gatekeeper-system" }, { "scope" => "gatekeeper" } ],
    "ns-gatekeeper-system-object" => [ { "identifier" => "core/Namespace/_cluster/gatekeeper-system" }, { "identifier" => "core/Namespace/_cluster/gatekeeper" } ],
    "aks-gatekeeper-crds" => [ { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/constrainttemplates.templates.gatekeeper.sh" }, { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/foo.gatekeeper.sh.example.com" } ],
    "aks-policy-templates" => [ { "identifier" => "templates.gatekeeper.sh/ConstraintTemplate/_cluster/k8sazurecontainerlimits" }, { "identifier" => "templates.gatekeeper.sh/ConstraintTemplate/_cluster/k8srequiredlabels" } ],
    "aks-policy-constraints" => [ { "identifier" => "constraints.gatekeeper.sh/K8sAzureV1/_cluster/azurepolicy-abc" }, { "identifier" => "constraints.gatekeeper.sh/K8sRequiredLabels/_cluster/team-labels" } ],
    "ns-calico-system" => [ { "scope" => "calico-system" }, { "scope" => "calico" } ],
    "ns-calico-system-object" => [ { "identifier" => "core/Namespace/_cluster/calico-system" }, { "identifier" => "core/Namespace/_cluster/calico" } ],
    "ns-tigera-operator" => [ { "scope" => "tigera-operator" }, { "scope" => "tigera" } ],
    "ns-tigera-operator-object" => [ { "identifier" => "core/Namespace/_cluster/tigera-operator" }, { "identifier" => "core/Namespace/_cluster/tigera" } ],
    "aks-calico-crds" => [ { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/felixconfigurations.crd.projectcalico.org" }, { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/foo.example.com" } ],
    "aks-tigera-crds" => [ { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/installations.operator.tigera.io" }, { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/foo.example.com" } ],
    "ns-app-routing-system" => [ { "scope" => "app-routing-system" }, { "scope" => "app-routing" } ],
    "ns-app-routing-system-object" => [ { "identifier" => "core/Namespace/_cluster/app-routing-system" }, { "identifier" => "core/Namespace/_cluster/app-routing" } ],
    "ns-aks-istio" => [ { "scope" => "aks-istio-system" }, { "scope" => "istio-system" } ],
    "ns-aks-istio-object" => [ { "identifier" => "core/Namespace/_cluster/aks-istio-ingress" }, { "identifier" => "core/Namespace/_cluster/istio-system" } ],
    "aks-crds" => [ { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/foo.kubernetes.azure.com" }, { "identifier" => "apiextensions.k8s.io/CustomResourceDefinition/_cluster/resourcegroups.resources.azure.com" } ],
    "aks-storageclass-default" => [ { "identifier" => "storage.k8s.io/StorageClass/_cluster/default" }, { "identifier" => "storage.k8s.io/StorageClass/_cluster/default-fast" } ],
    "aks-storageclass-managed" => [ { "identifier" => "storage.k8s.io/StorageClass/_cluster/managed-premium" }, { "identifier" => "storage.k8s.io/StorageClass/_cluster/premium-ssd" } ],
    "aks-storageclass-azurefile" => [ { "identifier" => "storage.k8s.io/StorageClass/_cluster/azurefile-csi" }, { "identifier" => "storage.k8s.io/StorageClass/_cluster/nfs" } ],
    "aks-csidrivers" => [ { "identifier" => "storage.k8s.io/CSIDriver/_cluster/disk.csi.azure.com" }, { "identifier" => "storage.k8s.io/CSIDriver/_cluster/ebs.csi.aws.com" } ]
  }.freeze

  def argo_rules
    BuiltinIgnoreRules.for("argocd")
  end

  test "argocd rules have unique keys, valid fields and short patterns" do
    rules = argo_rules
    assert_equal rules.map(&:key).uniq, rules.map(&:key)
    assert rules.all? { |r| UnmanagedIgnoreRule::FIELDS.include?(r.field) }
    assert rules.all? { |r| UnmanagedIgnoreRule::MATCH_TYPES.include?(r.match_type) }
    assert rules.all? { |r| r.pattern.length <= UnmanagedIgnoreRule::PATTERN_MAX_LENGTH }
    assert rules.all? { |r| r.ignore_reason.start_with?("Built-in: ") }
  end

  test "every argocd rule has a table-driven case" do
    assert_equal argo_rules.map(&:key).sort, ARGO_CASES.keys.sort
  end

  ARGO_CASES.each do |key, (hit, near_miss)|
    test "argocd built-in #{key} matches its example and not its near miss" do
      rule = argo_rules.find { |r| r.key == key }
      assert rule.matches?(hit), "expected #{key} to match #{hit}"
      assert_not rule.matches?(near_miss), "expected #{key} not to match #{near_miss}"
    end
  end

  test "argocd built-ins do not hide the contents of the default namespace" do
    attrs = { "identifier" => "core/ConfigMap/default/app", "scope" => "default", "name" => "app" }
    assert argo_rules.none? { |r| r.matches?(attrs) }
  end

  test "argocd built-ins do not hide ordinary workloads" do
    attrs = { "identifier" => "apps/Deployment/shop/web", "scope" => "shop", "name" => "web" }
    assert argo_rules.none? { |r| r.matches?(attrs) }
  end

  test "azure and argocd rules are kept apart" do
    assert_equal 11, BuiltinIgnoreRules.for("azure").size
    assert_empty BuiltinIgnoreRules.for("azure").map(&:key) & argo_rules.map(&:key)
    project = Project.create!(name: "Rules", key: "argo-rules")
    environment = project.environments.create!(name: "Prod", key: "prod-aks-argocd")
    custom = environment.unmanaged_ignore_rules.create!(pattern: "core/ConfigMap/*/scratch", source: "azure")
    effective = UnmanagedIgnoreRule.effective_rules(environment, "argocd")
    assert_equal argo_rules, effective.first(argo_rules.size)
    assert_not_includes effective, custom
    assert_equal BuiltinIgnoreRules.for("azure"), UnmanagedIgnoreRule.effective_rules(environment, "azure").first(11)
  end
end
