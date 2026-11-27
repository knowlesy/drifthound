require "test_helper"

class MetricsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_metrics_enabled = Rails.application.config.metrics_enabled
    @original_public_mode = Rails.application.config.public_mode
    Rails.application.config.metrics_enabled = true
    Rails.application.config.public_mode = false

    @read_token = ApiToken.create!(name: "prom", access: "read")
    @header = { "Authorization" => "Bearer #{@read_token.token}" }

    @project = Project.create!(name: "Metrics Project", key: "metrics-project")
    @env = @project.environments.create!(name: "Prod", key: "prod")
  end

  teardown do
    Rails.application.config.metrics_enabled = @original_metrics_enabled
    Rails.application.config.public_mode = @original_public_mode
  end

  def scrape(headers = @header)
    get metrics_path, headers: headers
    response.body
  end

  def series(body, name, **labels)
    body.lines.map(&:chomp).select do |line|
      line.match?(/\A#{name}[{ ]/) && labels.all? { |key, value| line.include?(%(#{key}="#{value}")) }
    end
  end

  def value(line)
    Float(line.split.last)
  end

  def env_series(body, name, env = @env, **labels)
    series(body, name, project: env.project.key, environment: env.key, **labels)
  end

  def create_check(environment, at:, **attrs)
    travel_to(at) do
      environment.drift_checks.create!({ status: :ok }.merge(attrs))
    end
  end

  # Authentication and behaviour

  test "disabled endpoint returns 404 with a valid token" do
    Rails.application.config.metrics_enabled = false

    get metrics_path, headers: @header

    assert_response :not_found
    assert_not_includes response.body, "drifthound_"
  end

  test "disabled endpoint returns 404 without a token" do
    Rails.application.config.metrics_enabled = false

    get metrics_path

    assert_response :not_found
  end

  test "enabled endpoint rejects a missing or invalid token" do
    get metrics_path
    assert_response :unauthorized

    get metrics_path, headers: { "Authorization" => "Bearer nope" }
    assert_response :unauthorized
  end

  test "read token gets the Prometheus text format" do
    get metrics_path, headers: @header

    assert_response :success
    assert response.content_type.start_with?("text/plain")
    assert_includes response.content_type, "version=0.0.4"
  end

  test "read_plans and write tokens are accepted" do
    [ ApiToken.create!(name: "plans", access: "read_plans"), ApiToken.create!(name: "ci") ].each do |token|
      get metrics_path, headers: { "Authorization" => "Bearer #{token.token}" }
      assert_response :success
    end
  end

  test "public mode does not open the endpoint" do
    Rails.application.config.public_mode = true

    get metrics_path

    assert_response :unauthorized
  end

  # Metrics

  test "build_info carries the version" do
    lines = series(scrape, "drifthound_build_info")

    assert_equal 1, lines.size
    assert_includes lines.first, %(version="#{Drifthound::Version}")
    assert_equal 1.0, value(lines.first)
  end

  test "environment_info carries the display names" do
    lines = env_series(scrape, "drifthound_environment_info")

    assert_equal 1, lines.size
    assert_includes lines.first, %(project_name="Metrics Project")
    assert_includes lines.first, %(environment_name="Prod")
    assert_equal 1.0, value(lines.first)
  end

  test "status has one series per status with the current one set to 1" do
    @env.update_columns(status: Environment.statuses[:drift])

    lines = env_series(scrape, "drifthound_environment_status")

    assert_equal 4, lines.size
    values = lines.to_h { |line| [ line[/status="(\w+)"/, 1], value(line) ] }
    assert_equal({ "unknown" => 0.0, "ok" => 0.0, "drift" => 1.0, "error" => 0.0 }, values)
  end

  test "last check timestamp is taken from the latest check" do
    create_check(@env, at: 2.hours.ago)
    newest = create_check(@env, at: 1.hour.ago)

    lines = env_series(scrape, "drifthound_environment_last_check_timestamp_seconds")

    assert_equal 1, lines.size
    assert_in_delta newest.created_at.to_f, value(lines.first), 1e-3
  end

  test "the higher id wins when checks share a created_at" do
    at = 1.hour.ago
    create_check(@env, at: at, duration: 10, add_count: 1, change_count: 1, destroy_count: 1)
    create_check(@env, at: at, duration: 20, add_count: 2, change_count: 2, destroy_count: 2)

    body = scrape

    assert_equal 20.0, value(env_series(body, "drifthound_environment_last_check_duration_seconds").first)
    assert_equal [ 2.0 ], env_series(body, "drifthound_environment_pending_changes", action: "add").map { |l| value(l) }
  end

  test "last check timestamp comes back as a time and not a string" do
    check = create_check(@env, at: 1.hour.ago)

    environment = MetricsExporter.new.send(:environments).find { |e| e.id == @env.id }

    assert_kind_of Time, environment.last_check_at
    assert_in_delta check.created_at.to_f, environment.last_check_at.to_f, 1e-3
  end

  test "duration comes from the latest check" do
    create_check(@env, at: 2.hours.ago, duration: 11)
    create_check(@env, at: 1.hour.ago, duration: 42)

    lines = env_series(scrape, "drifthound_environment_last_check_duration_seconds")

    assert_equal [ 42.0 ], lines.map { |line| value(line) }
  end

  test "a nil duration on the latest check omits the duration series" do
    create_check(@env, at: 2.hours.ago, duration: 11)
    create_check(@env, at: 1.hour.ago, duration: nil)

    body = scrape

    assert_empty env_series(body, "drifthound_environment_last_check_duration_seconds")
    assert_equal 1, env_series(body, "drifthound_environment_last_check_timestamp_seconds").size
  end

  test "pending changes use the counts of the latest check" do
    create_check(@env, at: 2.hours.ago, status: :drift, add_count: 9, change_count: 9, destroy_count: 9)
    create_check(@env, at: 1.hour.ago, status: :drift, add_count: 1, change_count: 2, destroy_count: 3)

    lines = env_series(scrape, "drifthound_environment_pending_changes")

    values = lines.to_h { |line| [ line[/action="(\w+)"/, 1], value(line) ] }
    assert_equal({ "add" => 1.0, "change" => 2.0, "destroy" => 3.0 }, values)
  end

  test "a nil count omits only that action" do
    create_check(@env, at: 1.hour.ago, status: :drift, add_count: 1, change_count: nil, destroy_count: 0)

    lines = env_series(scrape, "drifthound_environment_pending_changes")

    assert_equal %w[ add destroy ], lines.map { |line| line[/action="(\w+)"/, 1] }.sort
  end

  test "excluded environments are exported and flagged" do
    excluded = @project.environments.create!(name: "Sandbox", key: "sandbox", exclude_from_metrics: true)
    create_check(excluded, at: 1.hour.ago)

    body = scrape

    assert_equal [ 1.0 ], env_series(body, "drifthound_environment_excluded_from_metrics", excluded).map { |l| value(l) }
    assert_equal [ 0.0 ], env_series(body, "drifthound_environment_excluded_from_metrics").map { |l| value(l) }
    assert_equal 1, env_series(body, "drifthound_environment_info", excluded).size
    assert_equal 4, env_series(body, "drifthound_environment_status", excluded).size
    assert_equal 1, env_series(body, "drifthound_environment_last_check_timestamp_seconds", excluded).size
  end

  test "an environment without checks exports only info, status and excluded" do
    body = scrape

    assert_equal 1, env_series(body, "drifthound_environment_info").size
    assert_equal 1, env_series(body, "drifthound_environment_excluded_from_metrics").size
    unknown = env_series(body, "drifthound_environment_status", status: "unknown")
    assert_equal [ 1.0 ], unknown.map { |line| value(line) }
    assert_empty env_series(body, "drifthound_environment_last_check_timestamp_seconds")
    assert_empty env_series(body, "drifthound_environment_last_check_duration_seconds")
    assert_empty env_series(body, "drifthound_environment_pending_changes")
  end

  test "plan output is never exported or selected" do
    create_check(@env, at: 1.hour.ago, raw_output: "SECRET-PLAN-TEXT")

    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get metrics_path, headers: @header
    end

    assert_response :success
    assert_not_includes response.body, "SECRET-PLAN-TEXT"
    assert_not_includes response.body, "raw_output"
    assert queries.none? { |q| q.include?("raw_output") }
  end

  test "label values are escaped" do
    @env.update_columns(name: %(Prod "EU" \\ west\nline))

    body = scrape

    assert_includes body, %(environment_name="Prod \\"EU\\" \\\\ west\\nline")
    assert(body.lines.all? { |line| line.start_with?("#", "drifthound_") })
  end

  test "scraping uses a fixed number of queries" do
    count_queries = lambda do
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        get metrics_path, headers: @header
      end
      queries
    end

    create_check(@env, at: 1.hour.ago)
    single = count_queries.call
    assert_equal 1, single.count { |q| q.include?("drift_checks") }
    assert single.find { |q| q.include?("drift_checks") }.include?(%("projects"))

    4.times do |i|
      env = @project.environments.create!(name: "Env #{i}", key: "env-#{i}")
      3.times { |n| create_check(env, at: (n + 1).hours.ago) }
    end
    many = count_queries.call

    assert_equal single.size, many.size
  end

  test "every metric has exactly one HELP and one TYPE line" do
    body = scrape

    MetricsExporter::METRIC_NAMES.each do |name|
      assert_equal 1, body.lines.count { |line| line.start_with?("# HELP #{name} ") }, name
      assert_equal 1, body.lines.count { |line| line.chomp == "# TYPE #{name} gauge" }, name
    end
  end

  test "a destroyed environment is absent on the next scrape" do
    gone = @project.environments.create!(name: "Gone", key: "gone")

    assert_equal 1, env_series(scrape, "drifthound_environment_info", gone).size

    gone.destroy!

    assert_empty env_series(scrape, "drifthound_environment_info", gone)
  end
end
