require "test_helper"

class Api::V1::UnmanagedIgnoreRulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @write_header = { "Authorization" => "Bearer #{ApiToken.create!(name: 'ci').token}" }
    @read_header = { "Authorization" => "Bearer #{ApiToken.create!(name: 'dash', access: 'read').token}" }
    @project = Project.create!(name: "Rules", key: "rules")
    @environment = @project.environments.create!(name: "Prod Azure", key: "prod-azure")
    @other_environment = @project.environments.create!(name: "Dev Azure", key: "dev-azure")
  end

  def rules_path(env = @environment)
    api_v1_project_environment_ignore_rules_path(@project.key, env.key)
  end

  def rule_path(rule, env = @environment)
    api_v1_project_environment_ignore_rule_path(@project.key, env.key, rule.id)
  end

  test "requires a token" do
    get rules_path, as: :json
    assert_response :unauthorized
  end

  test "index lists rules and built-in rules" do
    rule = @environment.unmanaged_ignore_rules.create!(pattern: "/x*", note: "why")
    @other_environment.unmanaged_ignore_rules.create!(pattern: "/other")

    get rules_path, headers: @write_header, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal [ rule.id ], body["ignore_rules"].map { |r| r["id"] }
    assert_equal({ "id" => rule.id, "field" => "identifier", "match_type" => "glob", "pattern" => "/x*", "source" => nil, "note" => "why" },
                 body["ignore_rules"].first.except("created_at"))
    builtin = body["builtin_rules"]["azure"]
    assert_equal 11, builtin.size
    assert_equal %w[key field match_type pattern note], builtin.first.keys
  end

  test "read token gets built-in rules but not the custom rules" do
    @environment.unmanaged_ignore_rules.create!(pattern: "/subscriptions/secret-sub/resourceGroups/rg1")

    get rules_path, headers: @read_header, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body["ignore_rules_restricted"]
    assert_not body.key?("ignore_rules")
    assert_equal 11, body["builtin_rules"]["azure"].size
    assert_not_includes response.body, "secret-sub"
  end

  test "read_plans token gets the custom rules" do
    token = ApiToken.create!(name: "plans", access: "read_plans")
    @environment.unmanaged_ignore_rules.create!(pattern: "/x")

    get rules_path, headers: { "Authorization" => "Bearer #{token.token}" }, as: :json

    assert_equal 1, response.parsed_body["ignore_rules"].size
    assert_not response.parsed_body.key?("ignore_rules_restricted")
  end

  test "a one-click pattern as long as an identifier is accepted" do
    post rules_path, params: { pattern: "/" + "a" * 1023, match_type: "exact" }, headers: @write_header, as: :json
    assert_response :created
  end

  test "create adds a rule with defaults" do
    assert_difference -> { @environment.unmanaged_ignore_rules.count }, 1 do
      post rules_path, params: { pattern: "*/foo/*" }, headers: @write_header, as: :json
    end

    assert_response :created
    body = response.parsed_body
    assert_equal "identifier", body["field"]
    assert_equal "glob", body["match_type"]
    assert_nil body["source"]
  end

  test "create accepts all fields" do
    post rules_path,
      params: { pattern: "tmp-*", field: "name", match_type: "exact", source: "azure", note: "temp" },
      headers: @write_header, as: :json

    assert_response :created
    rule = @environment.unmanaged_ignore_rules.last
    assert_equal [ "name", "exact", "azure", "temp" ], [ rule.field, rule.match_type, rule.source, rule.note ]
  end

  test "create returns 422 for invalid input" do
    [
      {},
      { pattern: "" },
      { pattern: "a" * 1025 },
      { pattern: "a\nb" },
      { pattern: "x", field: "tags" },
      { pattern: "x", match_type: "regex" },
      { pattern: "x", source: "bogus" },
      { pattern: "x", source: [ "azure" ] },
      { pattern: [ "x" ] },
      { pattern: "x", note: "n" * 256 }
    ].each do |params|
      assert_no_difference -> { UnmanagedIgnoreRule.count } do
        post rules_path, params: params, headers: @write_header, as: :json
      end
      assert_response :unprocessable_entity, params.inspect
      assert response.parsed_body["error"].present?
    end
  end

  test "create rejects duplicates" do
    post rules_path, params: { pattern: "/dup" }, headers: @write_header, as: :json
    post rules_path, params: { pattern: "/DUP" }, headers: @write_header, as: :json
    assert_response :unprocessable_entity
  end

  test "create enforces the per-environment limit" do
    now = Time.current
    UnmanagedIgnoreRule.insert_all!(Array.new(UnmanagedIgnoreRule::MAX_PER_ENVIRONMENT) do |i|
      { environment_id: @environment.id, field: "identifier", match_type: "glob", pattern: "/p#{i}", created_at: now, updated_at: now }
    end)

    post rules_path, params: { pattern: "/one-more" }, headers: @write_header, as: :json

    assert_response :unprocessable_entity
  end

  test "read token cannot create or delete" do
    rule = @environment.unmanaged_ignore_rules.create!(pattern: "/x")

    assert_no_difference -> { UnmanagedIgnoreRule.count } do
      post rules_path, params: { pattern: "/y" }, headers: @read_header, as: :json
      assert_response :forbidden
      delete rule_path(rule), headers: @read_header, as: :json
      assert_response :forbidden
    end
  end

  test "destroy removes the rule" do
    rule = @environment.unmanaged_ignore_rules.create!(pattern: "/x")

    assert_difference -> { UnmanagedIgnoreRule.count }, -1 do
      delete rule_path(rule), headers: @write_header, as: :json
    end

    assert_response :no_content
  end

  test "unknown project, environment or rule returns 404" do
    get api_v1_project_environment_ignore_rules_path("nope", @environment.key), headers: @write_header, as: :json
    assert_response :not_found

    get api_v1_project_environment_ignore_rules_path(@project.key, "nope"), headers: @write_header, as: :json
    assert_response :not_found

    post api_v1_project_environment_ignore_rules_path(@project.key, "nope"), params: { pattern: "/x" }, headers: @write_header, as: :json
    assert_response :not_found
    assert_equal 0, Environment.where(key: "nope").count

    delete api_v1_project_environment_ignore_rule_path(@project.key, @environment.key, 0), headers: @write_header, as: :json
    assert_response :not_found
  end

  test "a rule from another environment cannot be deleted" do
    rule = @other_environment.unmanaged_ignore_rules.create!(pattern: "/x")

    assert_no_difference -> { UnmanagedIgnoreRule.count } do
      delete rule_path(rule, @environment), headers: @write_header, as: :json
    end

    assert_response :not_found
  end
end
