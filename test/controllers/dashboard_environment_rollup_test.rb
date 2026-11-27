require "test_helper"

class DashboardEnvironmentRollupTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.public_mode = true

    @network = Project.create!(name: "network", key: "network")
    @database = Project.create!(name: "database", key: "database")
    @network_env = @network.environments.create!(name: "Production", key: "production")
    @database_env = @database.environments.create!(name: "Production", key: "production")
    @network_env.drift_checks.create!(status: :drift, add_count: 3, change_count: 2, destroy_count: 1)
    @database_env.drift_checks.create!(status: :error, add_count: 0, change_count: 0, destroy_count: 0)
  end

  teardown do
    Rails.application.config.public_mode = false
  end

  def group(key)
    "[data-environment-key='#{key}']"
  end

  test "rolls every project's environment with the same key into one group" do
    get root_path

    assert_response :success
    assert_select "#environments-table .env-group", 3
    assert_select "#{group('production')} .col-layer-count", "3 projects"
    assert_select "#{group('production')} .env-group-row .status-text--error", "ERROR"
    assert_select "#{group('production')} .rollup-count--ok", "1"
    assert_select "#{group('production')} .rollup-count--drift", "1"
    assert_select "#{group('production')} .rollup-count--error", "1"
    assert_select "#{group('production')} .env-group-row .col-counts", text: /3 \/ 2 \/ 1/
    assert_select "#{group('production')} .env-layer-row", 3
  end

  test "a layer's status comes from its latest check rather than the environment column" do
    get root_path

    assert_select "#{group('dev')} .env-group-row .status-text--unknown", "UNKNOWN"
  end

  test "only the latest check on a layer counts toward the totals" do
    @network_env.drift_checks.create!(status: :drift, add_count: 1, change_count: 1, destroy_count: 1, created_at: 1.minute.from_now)
    @database_env.destroy

    get root_path

    # The fixture layer is ok with 0/0/0, so the totals are exactly the newest network check.
    assert_select "#{group('production')} .env-group-row .col-counts", text: /\A\s*1 \/ 1 \/ 1\s*\z/
  end

  test "last check is the newest layer value and Never when none" do
    @network_env.update_columns(last_checked_at: 3.days.ago)
    @database_env.update_columns(last_checked_at: 2.hours.ago)
    environments(:production).update_columns(last_checked_at: 5.days.ago)
    sandbox = @network.environments.create!(name: "Sandbox", key: "sandbox")

    get root_path

    assert_select "#{group('production')} .env-group-row .col-time", text: /about 2 hours ago/
    assert_select "#{group('sandbox')} .env-group-row .col-time", text: /Never/
    assert_nil sandbox.last_checked_at
  end

  test "excluded layers are rolled up and flagged" do
    excluded = @network.environments.create!(name: "Sandbox", key: "sandbox", exclude_from_metrics: true)
    excluded.drift_checks.create!(status: :drift, add_count: 1, change_count: 0, destroy_count: 0)

    get root_path

    assert_select "#{group('sandbox')} .env-group-row .status-text--drift", "DRIFT"
    assert_select "#{group('sandbox')} .env-layer-row .badge-info", "Excluded from metrics"
  end

  test "same key with different names shows the key with every name" do
    @database_env.update!(name: "Prod")

    get root_path

    assert_select "#{group('production')} .env-link", "production"
    assert_select "#{group('production')} .env-names", text: /Production, Prod|Prod, Production/
    assert_select "#{group('production')}[data-search*=?]", "prod"
  end

  test "groups that share a display name show their key to tell them apart" do
    @network.environments.create!(name: "Staging", key: "stage-a")
    @network.environments.create!(name: "Staging", key: "stage-b")

    get root_path

    assert_select "#{group('stage-a')} .env-names", "stage-a"
    assert_select "#{group('stage-b')} .env-names", "stage-b"
    assert_select "#{group('dev')} .env-names", 0
  end

  test "links go to the environment overview and each layer's environment page" do
    get root_path

    assert_select "#{group('production')} .env-group-row a.env-link[href=?]", environment_overview_path("production")
    assert_select "#{group('production')} .env-layer-row a[href=?]", project_environment_path("network", "production")
    assert_select "#{group('production')} .env-layer-row a[href=?]", project_environment_path("database", "production")
    assert_select "#{group('production')} .row-link", 0
  end

  test "uses a custom project label" do
    with_project_label("Layer", "Layers") do
      get root_path

      assert_select "#environments-table .project-envs-header span", text: "Layers"
      assert_select "#{group('production')} .col-layer-count", "3 layers"
      assert_select "[data-group='project']", text: "By Layer"
    end
  end

  test "leaves the project-first table unchanged" do
    get root_path

    pairs = Environment.count
    assert_select "#projects-table .project-env-row", pairs
    assert_select "[data-group='environment']", text: "By Environment"
  end

  test "has no grouping toggle or roll-up rows without data" do
    Project.destroy_all

    get root_path

    assert_select "[data-group]", 0
    assert_select "#environments-table", 0
  end

  test "requires login when public mode is off and shows the roll-up to a logged-in viewer" do
    Rails.application.config.public_mode = false

    get root_path
    assert_redirected_to login_path

    post login_path, params: { email: users(:viewer).email, password: "testpass1" }
    get root_path
    assert_response :success
    assert_select ".environment-rollup-table"
  end
end
