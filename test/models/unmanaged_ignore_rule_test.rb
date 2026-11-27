require "test_helper"

class UnmanagedIgnoreRuleTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Rules Project", key: "rules-project")
    @environment = @project.environments.create!(name: "Prod", key: "prod-azure")
  end

  def build_rule(**attrs)
    @environment.unmanaged_ignore_rules.build({ pattern: "/subscriptions/*/resourceGroups/x" }.merge(attrs))
  end

  test "defaults to a glob rule on identifier" do
    rule = build_rule
    assert_equal "identifier", rule.field
    assert_equal "glob", rule.match_type
    assert rule.valid?
  end

  test "exact match ignores case" do
    rule = build_rule(match_type: "exact", pattern: "/Subscriptions/ABC/resourceGroups/RG")
    assert rule.matches?("identifier" => "/subscriptions/abc/resourcegroups/rg")
    assert_not rule.matches?("identifier" => "/subscriptions/abc/resourcegroups/rg2")
  end

  test "exact match does not treat glob characters specially" do
    rule = build_rule(match_type: "exact", pattern: "/a/*")
    assert rule.matches?("identifier" => "/a/*")
    assert_not rule.matches?("identifier" => "/a/b")
  end

  test "glob star crosses slashes and ignores case" do
    rule = build_rule(pattern: "/subscriptions/*/resourcegroups/MC_*")
    assert rule.matches?("identifier" => "/subscriptions/0000/resourceGroups/mc_rg/providers/a/b")
    assert_not rule.matches?("identifier" => "/subscriptions/0000/resourceGroups/app/providers/a/b")
  end

  test "glob question mark and character classes work" do
    assert build_rule(pattern: "/a/r?").matches?("identifier" => "/a/r1")
    assert build_rule(pattern: "/a/r[12]").matches?("identifier" => "/a/R2")
    assert_not build_rule(pattern: "/a/r[12]").matches?("identifier" => "/a/r3")
  end

  test "braces are literal" do
    rule = build_rule(pattern: "/a/{b,c}")
    assert_not rule.matches?("identifier" => "/a/b")
    assert rule.matches?("identifier" => "/a/{b,c}")
  end

  test "matches other fields and never matches an empty value" do
    rule = build_rule(field: "name", pattern: "tmp-*")
    assert rule.matches?("name" => "tmp-1")
    assert_not rule.matches?("identifier" => "tmp-1")
    assert_not build_rule(field: "location", pattern: "*").matches?("location" => nil)
  end

  test "description" do
    assert_equal "identifier matches /x*", build_rule(pattern: "/x*").description
    assert_equal "name = n", build_rule(field: "name", match_type: "exact", pattern: "n").description
  end

  test "validates field and match_type" do
    assert_not build_rule(field: "tags").valid?
    assert_not build_rule(match_type: "regex").valid?
    UnmanagedIgnoreRule::FIELDS.each { |f| assert build_rule(field: f).valid?, f }
  end

  test "validates source" do
    assert build_rule(source: nil).valid?
    assert build_rule(source: "azure").valid?
    assert_not build_rule(source: "bogus").valid?
  end

  test "validates pattern length and characters" do
    assert_not build_rule(pattern: "").valid?
    assert_not build_rule(pattern: "a" * 1025).valid?
    assert build_rule(pattern: "a" * 1024).valid?
    assert_not build_rule(pattern: "a\nb").valid?
    assert_not build_rule(pattern: "a\u0000b").valid?
    assert_not build_rule(pattern: "a\tb").valid?
    assert build_rule(pattern: "Failure Anomalies - *").valid?
  end

  test "validates note length" do
    assert_not build_rule(note: "n" * 256).valid?
  end

  test "pattern is unique per environment, field, match type and source ignoring case" do
    build_rule(pattern: "/Dup").save!
    duplicate = build_rule(pattern: "/dup")
    assert_not duplicate.valid?
    assert build_rule(pattern: "/dup", source: "azure").valid?
    assert build_rule(pattern: "/dup", match_type: "exact").valid?

    other = @project.environments.create!(name: "Dev", key: "dev-azure")
    assert other.unmanaged_ignore_rules.build(pattern: "/dup").valid?
  end

  test "caps rules per environment" do
    now = Time.current
    rows = Array.new(UnmanagedIgnoreRule::MAX_PER_ENVIRONMENT) do |i|
      { environment_id: @environment.id, field: "identifier", match_type: "glob", pattern: "/p#{i}", created_at: now, updated_at: now }
    end
    UnmanagedIgnoreRule.insert_all!(rows)

    rule = build_rule(pattern: "/one-too-many")
    assert_not rule.valid?
    assert rule.errors[:base].any?
  end

  test "effective_rules lists built-ins first then environment rules by id for the source" do
    first = build_rule(pattern: "/first").tap(&:save!)
    azure_only = build_rule(pattern: "/azure-only", source: "azure").tap(&:save!)
    argo_only = build_rule(pattern: "/argo-only", source: "argocd").tap(&:save!)

    azure = UnmanagedIgnoreRule.effective_rules(@environment, "azure")
    builtins = BuiltinIgnoreRules.for("azure")
    assert_equal builtins, azure.first(builtins.size)
    assert_equal [ first, azure_only ], azure.drop(builtins.size)

    terraform = UnmanagedIgnoreRule.effective_rules(@environment, "terraform")
    assert_equal [ first ], terraform
    assert_includes UnmanagedIgnoreRule.effective_rules(@environment, "argocd"), argo_only
  end

  test "ignore_reason and api_json" do
    rule = build_rule(pattern: "/x*", note: "why").tap(&:save!)
    assert_equal "Rule ##{rule.id}: identifier matches /x*", rule.ignore_reason
    assert_equal %i[id field match_type pattern source note created_at], rule.api_json.keys
  end

  test "created_by is optional and nullified when the user is deleted" do
    user = users(:admin)
    rule = build_rule(created_by: user).tap(&:save!)
    user.delete
    assert_nil rule.reload.created_by_id
  end

  test "Environment#destroy removes its rules" do
    build_rule.save!
    assert_difference "UnmanagedIgnoreRule.count", -1 do
      @environment.destroy
    end
  end

  test "Environment.delete_all succeeds with rules present" do
    build_rule.save!
    assert_nothing_raised { Environment.where(id: @environment.id).delete_all }
    assert_equal 0, UnmanagedIgnoreRule.where(environment_id: @environment.id).count
  end
end
