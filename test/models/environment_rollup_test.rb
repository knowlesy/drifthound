require "test_helper"

class EnvironmentRollupTest < ActiveSupport::TestCase
  setup do
    @index = 0
  end

  def add_layer(status: nil, counts: [ 0, 0, 0 ], key: "prod", name: "Production", excluded: false, last_checked_at: nil)
    @index += 1
    project = Project.create!(name: "project-#{@index}", key: "project-#{@index}")
    env = project.environments.create!(name: name, key: key, exclude_from_metrics: excluded, last_checked_at: last_checked_at)
    if status
      env.drift_checks.create!(status: status, add_count: counts[0], change_count: counts[1], destroy_count: counts[2])
    end
    [ project, env ]
  end

  def rollup_for(pairs, key = "prod")
    EnvironmentRollup.build(pairs).find { |rollup| rollup.key == key }
  end

  test "worst status is error when any layer errors" do
    rollup = rollup_for([ add_layer(status: :error), add_layer(status: :ok) ])
    assert_equal "error", rollup.worst_status
  end

  test "worst status is drift when drift and ok" do
    rollup = rollup_for([ add_layer(status: :drift), add_layer(status: :ok) ])
    assert_equal "drift", rollup.worst_status
  end

  test "ok mixed with unknown is unknown" do
    rollup = rollup_for([ add_layer(status: :ok), add_layer ])
    assert_equal "unknown", rollup.worst_status
  end

  test "drift outranks unknown" do
    rollup = rollup_for([ add_layer(status: :drift), add_layer ])
    assert_equal "drift", rollup.worst_status
  end

  test "worst status is ok when all layers are ok" do
    rollup = rollup_for([ add_layer(status: :ok), add_layer(status: :ok) ])
    assert_equal "ok", rollup.worst_status
  end

  test "status counts tally layers per status" do
    rollup = rollup_for([ add_layer(status: :ok), add_layer(status: :ok), add_layer(status: :drift), add_layer(status: :error), add_layer ])
    assert_equal({ "ok" => 2, "drift" => 1, "error" => 1, "unknown" => 1 }, rollup.status_counts)
  end

  test "totals sum the latest check counts and treat missing checks and nil counts as zero" do
    with_nil_counts = add_layer
    with_nil_counts.last.drift_checks.create!(status: :ok, add_count: nil, change_count: nil, destroy_count: nil)
    rollup = rollup_for([ add_layer(status: :drift, counts: [ 3, 2, 1 ]), add_layer(status: :drift, counts: [ 1, 1, 1 ]), add_layer, with_nil_counts ])

    assert_equal 4, rollup.add_total
    assert_equal 3, rollup.change_total
    assert_equal 2, rollup.destroy_total
  end

  test "only the latest check on a layer counts" do
    pair = add_layer(status: :drift, counts: [ 5, 0, 0 ])
    pair.last.drift_checks.create!(status: :drift, add_count: 1, change_count: 1, destroy_count: 1, created_at: 1.minute.from_now)
    rollup = rollup_for([ pair ])

    assert_equal [ 1, 1, 1 ], [ rollup.add_total, rollup.change_total, rollup.destroy_total ]
  end

  test "last checked is the newest value and nil when none" do
    older = add_layer(last_checked_at: 3.days.ago)
    newer = add_layer(last_checked_at: 1.day.ago)
    missing = add_layer

    assert_in_delta newer.last.last_checked_at.to_f, rollup_for([ older, newer, missing ]).last_checked_at.to_f, 1
    assert_nil rollup_for([ add_layer ]).last_checked_at
  end

  test "excluded layers are included" do
    rollup = rollup_for([ add_layer(status: :drift, excluded: true), add_layer(status: :ok) ])

    assert_equal 2, rollup.layers.size
    assert_equal "drift", rollup.worst_status
    assert_equal [ true, false ], rollup.layers.map(&:excluded?)
  end

  test "same key with different names is one group with both names and the key as display name" do
    rollup = rollup_for([ add_layer(name: "Production"), add_layer(name: "Prod") ])

    assert_equal [ "Production", "Prod" ], rollup.names
    assert_equal "prod", rollup.display_name
    assert_includes rollup.search_text, "production"
  end

  test "display name is the shared name when every layer agrees" do
    assert_equal "Production", rollup_for([ add_layer, add_layer ]).display_name
  end

  test "keys differing only by case are separate groups" do
    rollups = EnvironmentRollup.build([ add_layer(key: "Prod"), add_layer(key: "prod") ])

    assert_equal %w[Prod prod], rollups.map(&:key)
  end

  test "groups are sorted by key" do
    rollups = EnvironmentRollup.build([ add_layer(key: "staging"), add_layer(key: "dev"), add_layer(key: "prod") ])

    assert_equal %w[dev prod staging], rollups.map(&:key)
  end

  test "build runs a single query" do
    pairs = [ add_layer(status: :ok), add_layer(status: :drift, key: "staging") ]

    assert_queries_count(1) { EnvironmentRollup.build(pairs) }
  end

  test "accessors do not query" do
    rollup = rollup_for([ add_layer(status: :drift, counts: [ 1, 2, 3 ]), add_layer ])

    assert_no_queries do
      rollup.layers.each { |layer| [ layer.status, layer.add_count, layer.change_count, layer.destroy_count, layer.last_checked_at, layer.excluded?, layer.project.name ] }
      [ rollup.key, rollup.names, rollup.display_name, rollup.status_counts, rollup.worst_status, rollup.add_total, rollup.change_total, rollup.destroy_total, rollup.last_checked_at, rollup.search_text ]
    end
  end
end
