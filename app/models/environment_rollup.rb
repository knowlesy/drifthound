# Rolls up every project's environment that shares one environment key into a single row.
# A plain Ruby object: build it from [project, environment] pairs the caller has already loaded.
class EnvironmentRollup
  # Worst status last. Not the enum order, which is unknown/ok/drift/error.
  SEVERITY = %w[ok unknown drift error].freeze
  STATUSES = %w[ok drift error unknown].freeze

  Layer = Data.define(:project, :environment, :latest_check) do
    def status
      latest_check&.status || "unknown"
    end

    def add_count
      latest_check&.add_count.to_i
    end

    def change_count
      latest_check&.change_count.to_i
    end

    def destroy_count
      latest_check&.destroy_count.to_i
    end

    def last_checked_at
      environment.last_checked_at
    end

    def excluded?
      environment.exclude_from_metrics?
    end
  end

  attr_reader :key, :layers

  # pairs: [ [ project, environment ], ... ]. Runs one query for the latest checks.
  def self.build(pairs)
    latest_checks = Environment.latest_checks_for(pairs.map(&:last))

    pairs
      .group_by { |_project, environment| environment.key }
      .map do |key, group|
        layers = group.map { |project, environment| Layer.new(project: project, environment: environment, latest_check: latest_checks[environment.id]) }
        new(key, layers)
      end
      .sort_by { |rollup| [ rollup.key.downcase, rollup.key ] }
  end

  def initialize(key, layers)
    @key = key
    @layers = layers
  end

  # Distinct environment names, in layer order.
  def names
    layers.map { |layer| layer.environment.name }.uniq
  end

  # The shared name when every layer agrees, otherwise the key.
  def display_name
    names.one? ? names.first : key
  end

  def status_counts
    counts = STATUSES.index_with(0)
    layers.each { |layer| counts[layer.status] += 1 if counts.key?(layer.status) }
    counts
  end

  def worst_status
    layers.map(&:status).max_by { |status| SEVERITY.index(status) || SEVERITY.index("unknown") } || "unknown"
  end

  def add_total
    layers.sum(&:add_count)
  end

  def change_total
    layers.sum(&:change_count)
  end

  def destroy_total
    layers.sum(&:destroy_count)
  end

  def last_checked_at
    layers.filter_map(&:last_checked_at).max
  end

  def search_text
    [ key, *names ].join(" ").downcase
  end
end
