require "test_helper"

class UnmanagedResourceTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Test Project", key: "unmanaged-test")
    @environment = @project.environments.create!(name: "Prod", key: "prod-azure")
    @check = @environment.drift_checks.create!(status: :drift, source: "azure", unmanaged_count: 1, unmanaged_ignored_count: 0)
  end

  def create_resource(check = @check, **attrs)
    check.unmanaged_resources.create!({ identifier: "/subscriptions/0000/resourceGroups/rg1" }.merge(attrs))
  end

  test "requires an identifier" do
    resource = @check.unmanaged_resources.build
    assert_not resource.valid?
    assert_includes resource.errors[:identifier], "can't be blank"
  end

  test "enforces field length limits" do
    resource = @check.unmanaged_resources.build(identifier: "a" * 1025, location: "l" * 129, scope: "s" * 256)
    assert_not resource.valid?
    assert resource.errors[:identifier].any?
    assert resource.errors[:location].any?
    assert resource.errors[:scope].any?
  end

  test "stores a scope column and metadata" do
    resource = create_resource(scope: "rg1", metadata: { "tags" => { "owner" => "x" } })
    assert_equal "rg1", resource.reload.scope
    assert_equal({ "owner" => "x" }, resource.metadata["tags"])
  end

  test "reported and ignored_rows scopes" do
    kept = create_resource(identifier: "/a")
    hidden = create_resource(identifier: "/b", ignored: true, ignore_reason: "Built-in: x")
    assert_equal [ kept ], @check.unmanaged_resources.reported.to_a
    assert_equal [ hidden ], @check.unmanaged_resources.ignored_rows.to_a
  end

  test "api_json shape" do
    resource = create_resource(resource_type: "t", name: "n", scope: "s", location: "l")
    assert_equal(
      %i[identifier resource_type name scope location metadata ignored ignore_reason],
      resource.api_json.keys
    )
    assert_equal false, resource.api_json[:ignored]
  end

  test "delete_checks_before removes unmanaged resources" do
    create_resource
    @check.update_columns(created_at: 10.days.ago)
    assert_difference "UnmanagedResource.count", -1 do
      @environment.delete_checks_before(1.day.ago)
    end
  end

  test "destroying a check removes its unmanaged resources" do
    create_resource
    assert_difference "UnmanagedResource.count", -1 do
      @check.destroy
    end
  end

  test "DriftCheck.delete_all succeeds with unmanaged resources present" do
    create_resource
    assert_nothing_raised { DriftCheck.delete_all }
    assert_equal 0, UnmanagedResource.count
  end
end
