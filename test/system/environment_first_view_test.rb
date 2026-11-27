require "application_system_test_case"

class EnvironmentFirstViewTest < ApplicationSystemTestCase
  def setup
    Rails.application.config.public_mode = true

    @network = Project.create!(name: "network", key: "network")
    @database = Project.create!(name: "database", key: "database")
    @network_env = @network.environments.create!(name: "Production", key: "layer-prod")
    @database_env = @database.environments.create!(name: "Production", key: "layer-prod")
    @staging_env = @network.environments.create!(name: "Staging", key: "layer-stage")
    @network_env.drift_checks.create!(status: :drift, add_count: 1, change_count: 0, destroy_count: 0)
    @database_env.drift_checks.create!(status: :ok, add_count: 0, change_count: 0, destroy_count: 0)
    @staging_env.drift_checks.create!(status: :ok, add_count: 0, change_count: 0, destroy_count: 0)

    visit root_path
    page.execute_script("localStorage.removeItem('dashboardGrouping')")
  end

  def teardown
    page.execute_script("localStorage.removeItem('dashboardGrouping')")
    Rails.application.config.public_mode = false
  end

  def resize_to(width)
    page.driver.browser.manage.window.resize_to(width, 900)
  end

  def switch_to_environments
    visit root_path
    find("[data-group='environment']").click
    assert_selector ".environment-rollup-table"
  end

  test "toggle swaps the tables and a group expands and collapses" do
    visit root_path
    assert_selector ".projects-table"
    assert_no_selector ".environment-rollup-table"

    find("[data-group='environment']").click
    assert_selector ".environment-rollup-table"
    assert_no_selector ".projects-table"
    assert_no_selector ".env-layer-row"

    within(".env-group[data-environment-key='layer-prod']") do
      find(".expand-btn").click
      assert_selector ".env-layer-row", count: 2
      assert_selector ".expand-btn[aria-expanded='true']"
    end
    assert_selector ".env-group.expanded"

    within(".env-group[data-environment-key='layer-prod']") { find(".expand-btn").click }
    assert_no_selector ".env-layer-row"
    within(".env-group[data-environment-key='layer-prod']") { assert_selector ".expand-btn[aria-expanded='false']" }
  end

  test "layer link opens the project environment page" do
    switch_to_environments
    within(".env-group[data-environment-key='layer-prod']") do
      find(".expand-btn").click
      click_link "network"
    end
    assert_current_path project_environment_path("network", "layer-prod")
  end

  test "environment label opens the overview without toggling the row" do
    switch_to_environments
    within(".env-group[data-environment-key='layer-prod']") { click_link "Production" }
    assert_current_path environment_overview_path("layer-prod")
  end

  test "the grouping choice is remembered" do
    switch_to_environments
    visit root_path
    assert_selector ".environment-rollup-table"
    assert_no_selector ".projects-table"

    find("[data-group='project']").click
    assert_selector ".projects-table"
    assert_no_selector ".environment-rollup-table"
  end

  test "status filter hides groups with no layer in that status" do
    switch_to_environments
    assert_selector ".env-group[data-environment-key='layer-stage']"

    find(".status-badge.status-drift").click

    assert_selector ".env-group[data-environment-key='layer-prod']"
    assert_no_selector ".env-group[data-environment-key='layer-stage']"
  end

  test "expand button label follows the expanded state" do
    switch_to_environments
    within(".env-group[data-environment-key='layer-prod']") do
      assert_selector ".expand-btn[aria-label^='Show']"
      find(".expand-btn").click
      assert_selector ".expand-btn[aria-label^='Hide']"
      find(".expand-btn").click
      assert_selector ".expand-btn[aria-label^='Show']"
    end
  end

  test "no horizontal overflow on phones in either grouping" do
    [ 360, 390, 480, 600 ].each do |width|
      resize_to(width)
      visit root_path
      assert_selector ".projects-table"
      assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth"), "project-first overflows at #{width}px"

      find("[data-group='environment']").click
      assert_selector ".environment-rollup-table"
      find(".env-group[data-environment-key='layer-prod'] .expand-btn").click
      assert_selector ".env-layer-row", count: 2
      assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth"), "env-first overflows at #{width}px"

      page.execute_script("localStorage.removeItem('dashboardGrouping')")
    end
  ensure
    resize_to(1400)
  end
end
