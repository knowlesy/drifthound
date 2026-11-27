require "test_helper"

class DriftChecksControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.public_mode = false
    DriftCheck.delete_all
    Environment.delete_all
    Project.delete_all
    @project = Project.create!(name: "Clear Project", key: "clear-project")
    @env = @project.environments.create!(name: "Staging", key: "staging")
    @old_ok = travel_to(10.days.ago) { @env.drift_checks.create!(status: :ok) }
    @new_drift = travel_to(1.day.ago) { @env.drift_checks.create!(status: :drift, add_count: 2) }
    post login_path, params: { email: users(:admin).email, password: "testpass1" }
  end

  def login_as(user)
    delete logout_path
    post login_path, params: { email: user.email, password: "testpass1" }
  end

  test "admin deletes a single check" do
    delete project_environment_check_path(@project.key, @env.key, @new_drift)

    assert_redirected_to project_environment_path(@project.key, @env.key)
    assert_equal "Check ##{@new_drift.execution_number} has been deleted", flash[:notice]
    assert_equal [ @old_ok.id ], @env.drift_checks.pluck(:id)
  end

  test "dashboard and environment status follow the newest remaining check after a delete" do
    get root_path
    assert_select ".status-badge.status-drift .count", "1"

    delete project_environment_check_path(@project.key, @env.key, @new_drift)

    @env.reload
    assert_equal "ok", @env.status
    assert_in_delta @old_ok.created_at.to_f, @env.last_checked_at.to_f, 0.001
    get root_path
    assert_select ".status-badge.status-ok .count", "1"
    assert_select ".status-badge.status-drift .count", "0"
    assert_select ".project-env-row.project-row--ok", 1
    get project_path(@project.key)
    assert_select ".environment-row .status-text--ok", 1
  end

  test "deleting a check from another environment returns not found" do
    other = @project.environments.create!(name: "Prod", key: "prod")
    check = other.drift_checks.create!(status: :ok)

    delete project_environment_check_path(@project.key, @env.key, check)

    assert_response :not_found
    assert DriftCheck.exists?(check.id)
  end

  test "non-admin cannot delete a check" do
    login_as(users(:editor))

    delete project_environment_check_path(@project.key, @env.key, @new_drift)

    assert_equal "You are not authorized to perform this action.", flash[:alert]
    assert DriftCheck.exists?(@new_drift.id)
  end

  test "anonymous user cannot delete a check" do
    delete logout_path

    delete project_environment_check_path(@project.key, @env.key, @new_drift)

    assert_redirected_to login_path
    assert DriftCheck.exists?(@new_drift.id)
  end

  test "admin clears checks before a date" do
    delete project_environment_checks_path(@project.key, @env.key), params: { before: 5.days.ago.to_date.iso8601 }

    assert_redirected_to project_environment_path(@project.key, @env.key)
    assert_equal "Deleted 1 check from before #{5.days.ago.to_date.iso8601}", flash[:notice]
    assert_equal [ @new_drift.id ], @env.drift_checks.pluck(:id)
    assert_equal "drift", @env.reload.status
  end

  test "clearing every check resets the environment to unknown" do
    delete project_environment_checks_path(@project.key, @env.key), params: { before: Date.tomorrow.iso8601 }

    assert_equal 0, @env.drift_checks.count
    assert_equal "unknown", @env.reload.status
    assert_nil @env.last_checked_at
  end

  test "clearing with an invalid date deletes nothing" do
    delete project_environment_checks_path(@project.key, @env.key), params: { before: "not-a-date" }

    assert_redirected_to project_environment_path(@project.key, @env.key)
    assert_equal "Choose a valid date to clear checks before", flash[:alert]
    assert_equal 2, @env.drift_checks.count
  end

  test "non-admin cannot clear checks" do
    login_as(users(:viewer))

    delete project_environment_checks_path(@project.key, @env.key), params: { before: Date.tomorrow.iso8601 }

    assert_equal "You are not authorized to perform this action.", flash[:alert]
    assert_equal 2, @env.drift_checks.count
  end

  test "admin sees delete and clear controls" do
    get project_environment_path(@project.key, @env.key)

    assert_select "form.delete-check-form[data-expandable-ignore] button", text: "Delete", count: 2
    assert_select "form.clear-checks-form input[type=date][name=before]", 1
  end

  test "viewer does not see delete or clear controls" do
    login_as(users(:viewer))

    get project_environment_path(@project.key, @env.key)

    assert_response :success
    assert_select "form.delete-check-form", 0
    assert_select "form.clear-checks-form", 0
  end

  # --- unmanaged resources frame ---

  def azure_check
    check = @env.drift_checks.create!(status: :drift, source: "azure", unmanaged_count: 1, unmanaged_ignored_count: 1)
    check.unmanaged_resources.create!(identifier: "/subscriptions/0000/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa1", resource_type: "microsoft.storage/storageaccounts", name: "sa1", scope: "rg1", location: "westeurope")
    check.unmanaged_resources.create!(identifier: "/subscriptions/0000/resourceGroups/MC_x", ignored: true, ignore_reason: "Built-in: AKS node resource group")
    check
  end

  test "unmanaged frame lists reported and ignored resources with an ignore button for admins" do
    check = azure_check

    get project_environment_check_unmanaged_path(@project.key, @env.key, check)

    assert_response :success
    assert_select "turbo-frame#unmanaged_drift_check_#{check.id}"
    assert_select ".unmanaged-table td", text: /storageAccounts\/sa1/
    assert_select "details.unmanaged-ignored td", text: "Built-in: AKS node resource group"
    assert_select "form[action=?] input[name='unmanaged_ignore_rule[pattern]'][value=?]",
      project_environment_ignore_rules_path(@project.key, @env.key),
      "/subscriptions/0000/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa1"
    assert_select "form input[name='unmanaged_ignore_rule[match_type]'][value=exact]"
  end

  test "unmanaged frame has no ignore button for viewers" do
    check = azure_check
    login_as users(:viewer)

    get project_environment_check_unmanaged_path(@project.key, @env.key, check)

    assert_response :success
    assert_select ".unmanaged-table td", text: /storageAccounts\/sa1/
    assert_select ".unmanaged-list form", count: 0
  end

  test "unmanaged frame is forbidden when plan output is restricted above the user's role" do
    check = azure_check
    original = Rails.application.config.plan_output_min_role
    Rails.application.config.plan_output_min_role = "admin"
    login_as users(:viewer)

    get project_environment_check_unmanaged_path(@project.key, @env.key, check)

    assert_response :forbidden
    assert_not_includes response.body, "storageAccounts"
  ensure
    Rails.application.config.plan_output_min_role = original
  end

  test "unmanaged frame follows public mode" do
    check = azure_check
    delete logout_path

    get project_environment_check_unmanaged_path(@project.key, @env.key, check)
    assert_redirected_to login_path

    Rails.application.config.public_mode = true
    get project_environment_check_unmanaged_path(@project.key, @env.key, check)
    assert_response :success
    assert_select ".unmanaged-list form", count: 0

    original = Rails.application.config.plan_output_min_role
    Rails.application.config.plan_output_min_role = "editor"
    get project_environment_check_unmanaged_path(@project.key, @env.key, check)
    assert_response :forbidden
  ensure
    Rails.application.config.public_mode = false
    Rails.application.config.plan_output_min_role = original if original
  end

  test "unmanaged frame is not found for another environment's check" do
    other_env = @project.environments.create!(name: "Other", key: "other")
    other_check = other_env.drift_checks.create!(status: :ok, source: "azure", unmanaged_count: 0)

    get project_environment_check_unmanaged_path(@project.key, @env.key, other_check)

    assert_response :not_found
  end

  test "history page embeds a lazy unmanaged frame only for checks with an inventory" do
    check = azure_check

    get project_environment_path(@project.key, @env.key)

    assert_select "turbo-frame#unmanaged_drift_check_#{check.id}[loading=lazy][src=?]",
      project_environment_check_unmanaged_path(@project.key, @env.key, check)
    assert_select "turbo-frame[id^=unmanaged_drift_check_]", count: 1
    assert_select ".expand-btn", text: /Details/
  end
end
