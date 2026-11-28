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
end
