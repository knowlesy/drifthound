require "test_helper"

class UnmanagedResourceIngestTest < ActiveSupport::TestCase
  SUB = "/subscriptions/00000000-0000-0000-0000-000000000000"

  setup do
    project = Project.create!(name: "Ingest", key: "ingest")
    @environment = project.environments.create!(name: "Prod", key: "prod-azure")
  end

  def ingest(items, source: "azure")
    UnmanagedResourceIngest.new(environment: @environment, source: source, items: items).call
  end

  def item(identifier = "#{SUB}/resourceGroups/app/providers/Microsoft.Storage/storageAccounts/sa1", **extra)
    { "identifier" => identifier }.merge(extra.stringify_keys)
  end

  def assert_invalid(message, items)
    error = assert_raises(UnmanagedResourceIngest::InvalidPayload) { ingest(items) }
    assert_match message, error.message
  end

  test "nil items means no inventory" do
    result = ingest(nil)
    assert_nil result.unmanaged_count
    assert_nil result.ignored_count
    assert_empty result.rows
  end

  test "empty array is an inventory with zero counts" do
    result = ingest([])
    assert_equal 0, result.unmanaged_count
    assert_equal 0, result.ignored_count
  end

  test "builds rows with every column key" do
    result = ingest([ item(resource_type: "microsoft.storage/storageaccounts", name: "sa1", scope: "app", location: "westeurope", metadata: { "tags" => { "a" => "b" } }) ])
    row = result.rows.first
    assert_equal %i[identifier resource_type name scope location metadata ignored ignore_reason].sort, row.keys.sort
    assert_equal "sa1", row[:name]
    assert_equal({ "tags" => { "a" => "b" } }, row[:metadata])
    assert_equal false, row[:ignored]
    assert_nil row[:ignore_reason]
    assert_equal 1, result.unmanaged_count
  end

  test "rows with missing optional fields use nil and empty metadata" do
    row = ingest([ item ]).rows.first
    assert_nil row[:name]
    assert_equal({}, row[:metadata])
  end

  test "rejects non-array and non-object payloads" do
    assert_invalid(/must be an array of objects/, "nope")
    assert_invalid(/must be an array of objects/, { "0" => item })
    assert_invalid(/must be an array of objects/, [ "x" ])
  end

  test "rejects more than 5000 items but accepts 5000" do
    assert_invalid(/more than 5000 items/, Array.new(5001) { |i| item("/a/#{i}") })
    assert_equal 5000, ingest(Array.new(5000) { |i| item("/a/#{i}") }).unmanaged_count
  end

  test "identifier must be a non-blank string" do
    assert_invalid(/unmanaged_resources\[0\]\.identifier/, [ {} ])
    assert_invalid(/unmanaged_resources\[1\]\.identifier/, [ item, item("   ") ])
    assert_invalid(/identifier/, [ item(1) ])
  end

  test "identifier is stripped and length limited" do
    assert_equal "/a", ingest([ item("  /a  ") ]).rows.first[:identifier]
    assert_invalid(/identifier is too long/, [ item("/" + "a" * 1024) ])
    assert_equal 1, ingest([ item("/" + "a" * 1023) ]).unmanaged_count
  end

  test "other fields must be strings within limits" do
    assert_invalid(/\[0\]\.name must be a string/, [ item(name: 5) ])
    assert_invalid(/\[0\]\.location is too long/, [ item(location: "l" * 129) ])
    assert_invalid(/\[0\]\.scope is too long/, [ item(scope: "s" * 256) ])
    assert_invalid(/\[0\]\.resource_type is too long/, [ item(resource_type: "t" * 256) ])
  end

  test "metadata must be an object within the size limit" do
    assert_invalid(/\[0\]\.metadata must be an object/, [ item(metadata: [ 1 ]) ])
    assert_invalid(/\[0\]\.metadata is too large/, [ item(metadata: { "tags" => "x" * 2100 }) ])
  end

  test "metadata size is measured as plain JSON, not with escaped ampersands" do
    tags = { "q" => "&" * 1500 }
    assert_equal 1, ingest([ item(metadata: { "tags" => tags }) ]).unmanaged_count
    assert_invalid(/metadata is too large/, [ item(metadata: { "tags" => { "q" => "&" * 2100 } }) ])
  end

  test "rejects NUL characters in strings and nested metadata" do
    assert_invalid(/identifier must not contain NUL/, [ item("/a\u0000b") ])
    assert_invalid(/name must not contain NUL/, [ item(name: "a\u0000") ])
    assert_invalid(/metadata must not contain NUL/, [ item(metadata: { "tags" => { "k" => "v\u0000" } }) ])
    assert_invalid(/metadata must not contain NUL/, [ item(metadata: { "k\u0000" => "v" }) ])
    assert_invalid(/metadata must not contain NUL/, [ item(metadata: { "list" => [ "x\u0000" ] }) ])
  end

  test "dedupes by identifier ignoring case, first wins" do
    result = ingest([ item("/A/b", name: "first"), item("/a/B", name: "second"), item("/c") ])
    assert_equal [ "first", nil ], result.rows.map { |r| r[:name] }
    assert_equal 2, result.unmanaged_count
  end

  test "built-in rules ignore matching rows with a reason" do
    result = ingest([ item("#{SUB}/resourceGroups/MC_rg_aks_westeurope/providers/Microsoft.Network/loadBalancers/kubernetes"), item ])
    ignored, kept = result.rows
    assert ignored[:ignored]
    assert_equal "Built-in: AKS node resource group", ignored[:ignore_reason]
    assert_not kept[:ignored]
    assert_equal 1, result.unmanaged_count
    assert_equal 1, result.ignored_count
  end

  test "environment rules ignore matching rows and the first match wins" do
    rule = @environment.unmanaged_ignore_rules.create!(pattern: "*/storageAccounts/sa*")
    @environment.unmanaged_ignore_rules.create!(pattern: "*")
    row = ingest([ item ]).rows.first
    assert row[:ignored]
    assert_equal "Rule ##{rule.id}: identifier matches */storageAccounts/sa*", row[:ignore_reason]
  end

  test "rules for other sources do not apply" do
    @environment.unmanaged_ignore_rules.create!(pattern: "*", source: "argocd")
    assert_not ingest([ item ]).rows.first[:ignored]
  end

  test "rules can match on other fields" do
    @environment.unmanaged_ignore_rules.create!(field: "name", match_type: "exact", pattern: "SA1")
    assert ingest([ item(name: "sa1") ]).rows.first[:ignored]
  end

  test "works with an unsaved environment" do
    result = UnmanagedResourceIngest.new(environment: Environment.new, source: "azure", items: [ item ]).call
    assert_equal 1, result.unmanaged_count
  end
end
