require "test_helper"

class EnvironmentPolicyTest < ActiveSupport::TestCase
  setup do
    @original_min_role = Rails.application.config.plan_output_min_role
    project = Project.create!(name: "Policy Project", key: "policy-project")
    @environment = project.environments.create!(name: "Production", key: "production")
  end

  teardown do
    Rails.application.config.plan_output_min_role = @original_min_role
  end

  test "view_plan? allows everyone including anonymous viewers by default" do
    Rails.application.config.plan_output_min_role = "viewer"

    [ nil, users(:viewer), users(:editor), users(:admin) ].each do |user|
      assert EnvironmentPolicy.new(user, @environment).view_plan?, "expected #{user&.role || 'anonymous'} to view plan output"
    end
  end

  test "view_plan? requires editor or above when minimum role is editor" do
    Rails.application.config.plan_output_min_role = "editor"

    assert_not EnvironmentPolicy.new(nil, @environment).view_plan?
    assert_not EnvironmentPolicy.new(users(:viewer), @environment).view_plan?
    assert EnvironmentPolicy.new(users(:editor), @environment).view_plan?
    assert EnvironmentPolicy.new(users(:admin), @environment).view_plan?
  end

  test "view_plan? requires admin when minimum role is admin" do
    Rails.application.config.plan_output_min_role = "admin"

    assert_not EnvironmentPolicy.new(nil, @environment).view_plan?
    assert_not EnvironmentPolicy.new(users(:viewer), @environment).view_plan?
    assert_not EnvironmentPolicy.new(users(:editor), @environment).view_plan?
    assert EnvironmentPolicy.new(users(:admin), @environment).view_plan?
  end
end
