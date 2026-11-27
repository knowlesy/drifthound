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

  # EXTENSION POINT: add "argocd" => [ ... ] for the Argo source.
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
    ].freeze
  }.freeze

  def self.for(source)
    REGISTRY.fetch(source.to_s, [])
  end
end
