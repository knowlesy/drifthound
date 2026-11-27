require "application_system_test_case"

class UnmanagedResourcesTest < ApplicationSystemTestCase
  IDENTIFIER = "/subscriptions/0000/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa1".freeze

  def setup
    Rails.application.config.public_mode = false
    @project = Project.create!(name: "Azure Project", key: "azure-project")
    @env = @project.environments.create!(name: "Prod Azure", key: "prod-azure", status: :drift)
    check = @env.drift_checks.create!(status: :drift, source: "azure", unmanaged_count: 1, unmanaged_ignored_count: 0, raw_output: "Subscriptions: 0000")
    check.unmanaged_resources.create!(identifier: IDENTIFIER, name: "sa1", resource_type: "microsoft.storage/storageaccounts")
  end

  test "admin expands a check, sees the list load lazily and ignores a resource" do
    log_in_as users(:admin)
    visit project_environment_path(@project.key, @env.key)

    assert_selector ".col-summary", text: "1 unmanaged"
    assert_no_selector ".check-output .unmanaged-table", visible: :all
    click_button "Details"

    assert_selector ".check-output .unmanaged-table td", text: IDENTIFIER
    click_button "Ignore"

    assert_selector ".ignore-rules .unmanaged-table td", text: IDENTIFIER
  end

  private

  def log_in_as(user)
    visit login_path
    fill_in "email", with: user.email
    fill_in "password", with: "testpass1"
    find("input[type=submit], button[type=submit]").click
    assert_selector ".top-nav", text: user.email
  end
end
