require "prometheus/client"
require "prometheus/client/formats/text"

# Renders the current drift state of every environment in the Prometheus text
# format. A fresh registry is built for every call, so deleted environments
# disappear on the next scrape and nothing is shared between requests.
class MetricsExporter
  STATUSES = Environment.statuses.keys.freeze
  ACTIONS = {
    "add" => :last_add_count,
    "change" => :last_change_count,
    "destroy" => :last_destroy_count
  }.freeze

  METRIC_NAMES = %i[
    drifthound_build_info
    drifthound_environment_info
    drifthound_environment_status
    drifthound_environment_last_check_timestamp_seconds
    drifthound_environment_last_check_duration_seconds
    drifthound_environment_pending_changes
    drifthound_environment_excluded_from_metrics
  ].freeze

  # The latest check of each environment, found with one index probe per
  # environment on (environment_id, created_at, id), read backwards.
  LATEST_CHECK_JOIN = <<~SQL.squish.freeze
    LEFT JOIN LATERAL (
      SELECT drift_checks.created_at, drift_checks.duration,
             drift_checks.add_count, drift_checks.change_count, drift_checks.destroy_count
      FROM drift_checks
      WHERE drift_checks.environment_id = environments.id
      ORDER BY drift_checks.created_at DESC, drift_checks.id DESC
      LIMIT 1
    ) latest_check ON TRUE
  SQL

  def self.render = new.render

  def render
    registry = Prometheus::Client::Registry.new
    gauges = register_gauges(registry)

    gauges[:build_info].set(1, labels: { version: Drifthound::Version })
    environments.each { |environment| record(gauges, environment) }

    Prometheus::Client::Formats::Text.marshal(registry)
  end

  private

  def register_gauges(registry)
    env_labels = %i[ project environment ]
    gauge = lambda do |name, docstring, labels|
      registry.register(Prometheus::Client::Gauge.new(name, docstring: docstring, labels: labels))
    end

    {
      build_info: gauge.call(:drifthound_build_info,
        "Running DriftHound version. Always 1.", [ :version ]),
      info: gauge.call(:drifthound_environment_info,
        "Display names of each environment and its project, for joins in dashboards. Always 1.",
        env_labels + %i[ project_name environment_name ]),
      status: gauge.call(:drifthound_environment_status,
        "Current status of each environment (ok, drift, error, unknown): 1 for the current status, 0 for the others.",
        env_labels + [ :status ]),
      timestamp: gauge.call(:drifthound_environment_last_check_timestamp_seconds,
        "Unix time of the latest drift check of each environment.", env_labels),
      duration: gauge.call(:drifthound_environment_last_check_duration_seconds,
        "Duration in whole seconds reported by the latest drift check of each environment.", env_labels),
      pending: gauge.call(:drifthound_environment_pending_changes,
        "Resources to add, change or destroy according to the latest drift check of each environment.",
        env_labels + [ :action ]),
      excluded: gauge.call(:drifthound_environment_excluded_from_metrics,
        "1 if the environment is excluded from the dashboard metrics, 0 otherwise.", env_labels)
    }
  end

  def environments
    Environment
      .joins(:project)
      .joins(LATEST_CHECK_JOIN)
      .select(
        "environments.id", "environments.key", "environments.name",
        "environments.status", "environments.exclude_from_metrics",
        "projects.key AS project_key", "projects.name AS project_name",
        "latest_check.created_at AS last_check_at",
        "latest_check.duration AS last_check_duration",
        "latest_check.add_count AS last_add_count",
        "latest_check.change_count AS last_change_count",
        "latest_check.destroy_count AS last_destroy_count"
      )
      .order("projects.key", "environments.key")
  end

  def record(gauges, environment)
    labels = { project: environment.project_key, environment: environment.key }

    gauges[:info].set(1, labels: labels.merge(
      project_name: environment.project_name, environment_name: environment.name
    ))
    STATUSES.each do |status|
      gauges[:status].set(environment.status == status ? 1 : 0, labels: labels.merge(status: status))
    end
    gauges[:excluded].set(environment.exclude_from_metrics ? 1 : 0, labels: labels)

    return if environment.last_check_at.nil?

    gauges[:timestamp].set(environment.last_check_at.to_f, labels: labels)
    gauges[:duration].set(environment.last_check_duration, labels: labels) unless environment.last_check_duration.nil?
    ACTIONS.each do |action, column|
      count = environment.public_send(column)
      gauges[:pending].set(count, labels: labels.merge(action: action)) unless count.nil?
    end
  end
end
