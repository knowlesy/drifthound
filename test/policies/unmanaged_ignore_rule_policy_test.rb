require "test_helper"

class UnmanagedIgnoreRulePolicyTest < ActiveSupport::TestCase
  test "only admins can create or destroy ignore rules" do
    assert UnmanagedIgnoreRulePolicy.new(users(:admin), UnmanagedIgnoreRule).create?
    assert UnmanagedIgnoreRulePolicy.new(users(:admin), UnmanagedIgnoreRule).destroy?

    [ nil, users(:viewer), users(:editor) ].each do |user|
      assert_not UnmanagedIgnoreRulePolicy.new(user, UnmanagedIgnoreRule).create?, "#{user&.role || 'anonymous'} create"
      assert_not UnmanagedIgnoreRulePolicy.new(user, UnmanagedIgnoreRule).destroy?, "#{user&.role || 'anonymous'} destroy"
    end
  end
end
