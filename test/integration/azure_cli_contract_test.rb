require_relative "../cli/cli_test_helper"

# Builds a real payload from the fixtures with the CLI and posts it to the API,
# so the CLI and the server cannot drift apart unnoticed.
class AzureCliContractTest < ActionDispatch::IntegrationTest
  include CliTestHelper
  include AzureCliFixtures

  setup do
    @auth_header = { "Authorization" => "Bearer #{ApiToken.create!(name: 'ci').token}" }
  end

  def payload_from_cli(**opts)
    runner = FakeRunner.new
    stub_az(runner)
    azure_payload(azure_opts(**opts), runner)
  end

  def post_payload(payload)
    post api_v1_environment_checks_path("contract", "prod-azure"), params: payload.to_json,
      headers: @auth_header.merge("Content-Type" => "application/json")
  end

  test "the server accepts the CLI payload, stores the rows and applies built-in rules" do
    payload = payload_from_cli
    assert_equal "ok", payload[:status]

    post_payload(payload)

    assert_response :created
    body = response.parsed_body
    assert_equal "azure", body["source"]
    assert_equal 3, body["unmanaged_count"]
    assert_equal 1, body["unmanaged_ignored_count"]
    assert_equal "drift", body["status"]

    check = DriftCheck.find(body["id"])
    assert check.source_azure?
    assert_equal 4, check.unmanaged_resources.count
    ignored = check.unmanaged_resources.ignored_rows.sole
    assert_equal "/subscriptions/#{S1}/resourceGroups/NetworkWatcherRG", ignored.identifier
    assert_equal "Built-in: Network Watcher resource group", ignored.ignore_reason
    stmanual = check.unmanaged_resources.find_by(name: "stmanual")
    assert_equal "rg-app", stmanual.scope
    assert_equal({ "owner" => "alice" }, stmanual.metadata["tags"])
    assert_equal "drift", Environment.find(check.environment_id).status
  end

  test "built-in rules ignore AKS node resource group rows the CLI passes through" do
    post_payload(payload_from_cli(include_managed_by: true))

    assert_response :created
    check = DriftCheck.find(response.parsed_body["id"])
    ignored = check.unmanaged_resources.ignored_rows.pluck(:identifier)
    assert_includes ignored, "/subscriptions/#{S1}/resourceGroups/MC_rg-app_aks-app_westeurope"
    assert_includes ignored, "/subscriptions/#{S1}/resourceGroups/MC_rg-app_aks-app_westeurope/providers/Microsoft.Network/loadBalancers/kubernetes"
    assert_includes ignored, "/subscriptions/#{S1}/resourceGroups/NetworkWatcherRG"
    assert_equal 4, check.unmanaged_count
    assert_equal 3, check.unmanaged_ignored_count.to_i
  end

  test "an error payload without a list is accepted and stays an error" do
    runner = FakeRunner.new { on(exit: 1, stderr: "az login required") }
    payload = azure_payload(azure_opts, runner)

    post_payload(payload)

    assert_response :created
    assert_equal "error", response.parsed_body["status"]
    assert_nil response.parsed_body["unmanaged_count"]
    assert_equal 0, UnmanagedResource.count
  end
end
