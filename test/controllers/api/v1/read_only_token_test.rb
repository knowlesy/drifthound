require "test_helper"

class Api::V1::ReadOnlyTokenTest < ActionDispatch::IntegrationTest
  setup do
    @read_token = ApiToken.create!(name: "dashboard", access: "read")
    @write_token = ApiToken.create!(name: "ci")
    @read_header = { "Authorization" => "Bearer #{@read_token.token}" }
    @write_header = { "Authorization" => "Bearer #{@write_token.token}" }

    @project = Project.create!(name: "Read Project", key: "read-project")
    @environment = @project.environments.create!(name: "Prod", key: "prod", status: :drift)
    @environment.drift_checks.create!(status: :drift, add_count: 1, change_count: 0, destroy_count: 0, raw_output: "Plan: 1 to add")
  end

  test "read token can list projects" do
    get api_v1_projects_path, headers: @read_header, as: :json
    assert_response :success
  end

  test "read token can show project" do
    get api_v1_project_path(@project.key), headers: @read_header, as: :json
    assert_response :success
  end

  test "read token can list environments" do
    get api_v1_project_environments_path(@project.key), headers: @read_header, as: :json
    assert_response :success
  end

  test "read token can show environment" do
    get api_v1_project_environment_path(@project.key, @environment.key), headers: @read_header, as: :json
    assert_response :success
  end

  test "read token can fetch drift" do
    get drift_api_v1_project_environment_path(@project.key, @environment.key), headers: @read_header, as: :json
    assert_response :success
    assert_equal "Plan: 1 to add", response.parsed_body["raw_output"]
  end

  test "read token can send HEAD requests" do
    head api_v1_projects_path, headers: @read_header
    assert_response :success
  end

  test "read token cannot submit drift checks" do
    assert_no_difference [ "DriftCheck.count", "Project.count", "Environment.count" ] do
      post api_v1_environment_checks_path(@project.key, "new-env"),
        params: { status: "ok", add_count: 0, change_count: 0, destroy_count: 0 },
        headers: @read_header,
        as: :json
    end

    assert_response :forbidden
    assert_equal({ "error" => "Forbidden: this API token is read-only" }, response.parsed_body)
  end

  test "write token can submit drift checks" do
    assert_difference "DriftCheck.count", 1 do
      post api_v1_environment_checks_path(@project.key, @environment.key),
        params: { status: "ok", add_count: 0, change_count: 0, destroy_count: 0 },
        headers: @write_header,
        as: :json
    end

    assert_response :created
  end

  test "write token can read" do
    get api_v1_projects_path, headers: @write_header, as: :json
    assert_response :success
  end

  test "missing token on write returns unauthorized" do
    post api_v1_environment_checks_path(@project.key, @environment.key),
      params: { status: "ok" },
      as: :json

    assert_response :unauthorized
  end

  test "invalid token on read returns unauthorized" do
    get api_v1_projects_path, headers: { "Authorization" => "Bearer invalid-token" }, as: :json
    assert_response :unauthorized
  end
end
