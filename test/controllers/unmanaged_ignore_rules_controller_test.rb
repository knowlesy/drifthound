require "test_helper"

class UnmanagedIgnoreRulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.public_mode = false
    @project = Project.create!(name: "Rules UI", key: "rules-ui")
    @env = @project.environments.create!(name: "Prod Azure", key: "prod-azure")
    @env_path = project_environment_path(@project.key, @env.key)
    @rules_path = project_environment_ignore_rules_path(@project.key, @env.key)
  end

  def login_as(user)
    post login_path, params: { email: user.email, password: "testpass1" }
  end

  def rule_params(**attrs)
    { unmanaged_ignore_rule: { field: "identifier", match_type: "glob", pattern: "*/tmp-*", source: "", note: "" }.merge(attrs) }
  end

  test "admin creates a rule recording who created it" do
    login_as users(:admin)

    assert_difference -> { @env.unmanaged_ignore_rules.count }, 1 do
      post @rules_path, params: rule_params(source: "azure", note: "temp")
    end

    assert_redirected_to @env_path
    assert_match "applies from the next check", flash[:notice]
    rule = @env.unmanaged_ignore_rules.last
    assert_equal users(:admin), rule.created_by
    assert_equal "azure", rule.source
    assert_equal "temp", rule.note
  end

  test "blank source means all sources" do
    login_as users(:admin)
    post @rules_path, params: rule_params(source: "")
    assert_nil @env.unmanaged_ignore_rules.last.source
  end

  test "invalid rule redirects with an alert and creates nothing" do
    login_as users(:admin)

    assert_no_difference -> { UnmanagedIgnoreRule.count } do
      post @rules_path, params: rule_params(pattern: "", field: "tags")
    end

    assert_redirected_to @env_path
    assert_match "Could not add the ignore rule", flash[:alert]
  end

  test "admin destroys a rule" do
    rule = @env.unmanaged_ignore_rules.create!(pattern: "/x")
    login_as users(:admin)

    assert_difference -> { UnmanagedIgnoreRule.count }, -1 do
      delete project_environment_ignore_rule_path(@project.key, @env.key, rule)
    end

    assert_redirected_to @env_path
  end

  test "a rule of another environment cannot be destroyed" do
    other = @project.environments.create!(name: "Dev", key: "dev-azure")
    rule = other.unmanaged_ignore_rules.create!(pattern: "/x")
    login_as users(:admin)

    assert_no_difference -> { UnmanagedIgnoreRule.count } do
      delete project_environment_ignore_rule_path(@project.key, @env.key, rule)
    end

    assert_response :not_found
  end

  test "viewer and editor are refused" do
    rule = @env.unmanaged_ignore_rules.create!(pattern: "/x")

    [ users(:viewer), users(:editor) ].each do |user|
      delete logout_path
      login_as user

      assert_no_difference -> { UnmanagedIgnoreRule.count } do
        post @rules_path, params: rule_params
        assert_match "not authorized", flash[:alert]
        delete project_environment_ignore_rule_path(@project.key, @env.key, rule)
        assert_match "not authorized", flash[:alert]
      end
    end
  end

  test "anonymous users are redirected to login" do
    rule = @env.unmanaged_ignore_rules.create!(pattern: "/x")

    assert_no_difference -> { UnmanagedIgnoreRule.count } do
      post @rules_path, params: rule_params
      assert_redirected_to login_path
      delete project_environment_ignore_rule_path(@project.key, @env.key, rule)
      assert_redirected_to login_path
    end
  end

  test "public mode does not let anonymous users manage rules" do
    Rails.application.config.public_mode = true

    assert_no_difference -> { UnmanagedIgnoreRule.count } do
      post @rules_path, params: rule_params
    end
    assert_redirected_to login_path
  ensure
    Rails.application.config.public_mode = false
  end

  test "environment page lists rules, built-ins and the add form for admins only" do
    @env.drift_checks.create!(status: :ok, source: "azure", unmanaged_count: 0, unmanaged_ignored_count: 0)
    @env.unmanaged_ignore_rules.create!(pattern: "*/tmp-*", note: "scratch")

    login_as users(:admin)
    get @env_path
    assert_select ".ignore-rules .unmanaged-table td", text: "*/tmp-*"
    assert_select ".ignore-rules form.ignore-rule-form"
    assert_select ".ignore-rules .builtin-rules td", text: "/subscriptions/*/resourceGroups/MC_*"

    delete logout_path
    login_as users(:viewer)
    get @env_path
    assert_select ".ignore-rules .unmanaged-table td", text: "*/tmp-*"
    assert_select ".ignore-rules form.ignore-rule-form", count: 0
    assert_select ".ignore-rules button", text: "Delete", count: 0
  end

  test "custom rules are hidden from users who cannot see plan output" do
    @env.drift_checks.create!(status: :ok, source: "azure", unmanaged_count: 0, unmanaged_ignored_count: 0)
    @env.unmanaged_ignore_rules.create!(pattern: "/subscriptions/secret-sub/resourceGroups/rg1")
    original = Rails.application.config.plan_output_min_role
    Rails.application.config.plan_output_min_role = "admin"
    login_as users(:viewer)

    get @env_path

    assert_select ".ignore-rules", text: /1 custom rule \(hidden\)/
    assert_select ".ignore-rules .builtin-rules"
    assert_not_includes response.body, "secret-sub"
  ensure
    Rails.application.config.plan_output_min_role = original
  end

  test "environment page hides the rules section for terraform-only environments" do
    @env.drift_checks.create!(status: :ok)
    login_as users(:admin)

    get @env_path

    assert_select ".ignore-rules", count: 0
  end
end
