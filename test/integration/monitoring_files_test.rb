require "test_helper"

class MonitoringFilesTest < ActiveSupport::TestCase
  ROOT = Rails.root

  def yaml(path) = YAML.safe_load_file(ROOT.join(path))

  test "prometheus scrapes the app with the token file" do
    config = yaml("dev/monitoring/prometheus.yml")
    job = config["scrape_configs"].find { |c| c["job_name"] == "drifthound" }

    assert_equal "/metrics", job["metrics_path"]
    assert_equal [ "app:3000" ], job["static_configs"].first["targets"]
    assert_equal "/etc/prometheus/.token", job["authorization"]["credentials_file"]
    assert_includes config["rule_files"], "/etc/prometheus/alerts.yml"
  end

  test "alerts file defines the four example alerts" do
    rules = yaml("dev/monitoring/alerts.yml")["groups"].flat_map { |g| g["rules"] }

    assert_equal %w[ DriftCheckFailing DriftCheckStale DriftDetected DriftWouldDestroyResources ],
                 rules.map { |r| r["alert"] }.sort
  end

  test "alerts and dashboard only use exported metric names" do
    known = MetricsExporter::METRIC_NAMES.map(&:to_s)

    %w[ dev/monitoring/alerts.yml dev/grafana/dashboards/drifthound.json ].each do |path|
      used = ROOT.join(path).read.scan(/drifthound_[a-z_]+/).uniq
      assert_empty used - known, "#{path} uses unknown metrics"
    end
  end

  test "dashboard datasources match the provisioned uid" do
    datasource = yaml("dev/grafana/provisioning/datasources/prometheus.yml")["datasources"].first
    dashboard = JSON.parse(ROOT.join("dev/grafana/dashboards/drifthound.json").read)
    uids = []
    walk = lambda do |node|
      case node
      when Hash
        uids << node["datasource"]["uid"] if node["datasource"].is_a?(Hash)
        node.each_value(&walk)
      when Array then node.each(&walk)
      end
    end
    walk.call(dashboard)

    assert_equal "drifthound", dashboard["uid"]
    assert_not_empty uids
    assert_equal [ datasource["uid"] ], uids.uniq
  end

  test "grafana dashboard provider is valid" do
    provider = yaml("dev/grafana/provisioning/dashboards/drifthound.yml")["providers"].first

    assert_equal "file", provider["type"]
    assert_equal "/etc/dashboards", provider["options"]["path"]
  end
end
