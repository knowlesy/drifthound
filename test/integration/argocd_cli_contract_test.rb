require_relative "../cli/argo_cli_helper"

# Builds a real payload from the fixture cluster with the CLI and posts it to the API,
# so the CLI and the server cannot drift apart unnoticed.
class ArgocdCliContractTest < ActionDispatch::IntegrationTest
  include CliTestHelper
  include ArgoCliFixtures

  setup do
    @auth_header = { "Authorization" => "Bearer #{ApiToken.create!(name: 'ci').token}" }
  end

  def payload_from_cli(**stub)
    argo_payload(argo_opts, argo_runner(**stub))
  end

  def post_payload(payload)
    post api_v1_environment_checks_path("platform", "prod-aks-argocd"), params: payload.to_json,
      headers: @auth_header.merge("Content-Type" => "application/json")
  end

  test "the server accepts the CLI payload, stores the rows and applies built-in rules" do
    payload = payload_from_cli
    assert_equal "ok", payload[:status]

    post_payload(payload)

    assert_response :created
    body = response.parsed_body
    assert_equal "argocd", body["source"]
    assert_equal 11, body["unmanaged_count"]
    assert_equal 8, body["unmanaged_ignored_count"]
    assert_equal "drift", body["status"]

    check = DriftCheck.find(body["id"])
    assert check.source_argocd?
    assert_equal 19, check.unmanaged_resources.count
    ignored = check.unmanaged_resources.ignored_rows.pluck(:identifier, :ignore_reason).to_h
    {
      "core/ConfigMap/shop/kube-root-ca.crt" => "Built-in: Per-namespace cluster CA ConfigMap",
      "core/ServiceAccount/shop/default" => "Built-in: Per-namespace default ServiceAccount",
      "core/Namespace/_cluster/default" => "Built-in: default namespace object (not its contents)",
      "core/Namespace/_cluster/kube-system" => "Built-in: kube-system namespace",
      "core/Service/default/kubernetes" => "Built-in: API server Service",
      "argoproj.io/AppProject/argocd/default" => "Built-in: Argo CD's built-in default AppProject",
      "rbac.authorization.k8s.io/ClusterRole/_cluster/system:foo" => "Built-in: Kubernetes system ClusterRoles",
      "apiextensions.k8s.io/CustomResourceDefinition/_cluster/applications.argoproj.io" => "Built-in: Argo CD CRD"
    }.each { |identifier, reason| assert_equal reason, ignored.fetch(identifier) }
    assert_equal 8, ignored.size

    reported = check.unmanaged_resources.reported.pluck(:identifier)
    assert_includes reported, "apps/Deployment/shop/redis"
    assert_includes reported, "core/ConfigMap/default/settings"
    assert_includes reported, "apps/Deployment/scratch/hand"
    assert_includes reported, "core/Namespace/_cluster/scratch"
    assert_equal "drift", Environment.find(check.environment_id).status
  end

  test "scope, location and metadata are stored" do
    post_payload(payload_from_cli)

    row = DriftCheck.find(response.parsed_body["id"]).unmanaged_resources.find_by(name: "hand")
    assert_equal "scratch", row.scope
    assert_equal "prod-aks", row.location
    assert_equal "Deployment.apps", row.resource_type
    assert_equal 2, row.metadata["dependents"]
    assert_equal "untracked", row.metadata["reason"]
    assert_nil DriftCheck.find(response.parsed_body["id"]).unmanaged_resources.find_by(name: "scratch").scope
  end

  test "an error payload without a list is accepted and stays an error" do
    payload = payload_from_cli(errors: { "pods" => [ "Error from server (Forbidden): pods is forbidden", 1 ] })
    assert_equal "error", payload[:status]

    post_payload(payload)

    assert_response :created
    assert_equal "error", response.parsed_body["status"]
    assert_nil response.parsed_body["unmanaged_count"]
    assert_equal 0, UnmanagedResource.count
  end

  test "an environment rule on scope applies to argocd rows" do
    project = Project.create!(name: "Platform", key: "platform")
    environment = project.environments.create!(name: "Prod AKS Argo CD", key: "prod-aks-argocd")
    rule = environment.unmanaged_ignore_rules.create!(field: "scope", match_type: "exact", pattern: "scratch", source: "argocd")

    post_payload(payload_from_cli)

    assert_response :created
    assert_equal 10, response.parsed_body["unmanaged_count"]
    hand = DriftCheck.find(response.parsed_body["id"]).unmanaged_resources.find_by(name: "hand")
    assert hand.ignored
    assert_equal "Rule ##{rule.id}: scope = scratch", hand.ignore_reason
  end

  test "rules for another source do not apply" do
    project = Project.create!(name: "Platform", key: "platform")
    project.environments.create!(name: "Prod AKS Argo CD", key: "prod-aks-argocd")
      .unmanaged_ignore_rules.create!(field: "scope", match_type: "exact", pattern: "scratch", source: "azure")

    post_payload(payload_from_cli)

    assert_equal 11, response.parsed_body["unmanaged_count"]
  end

  test "the server accepts metadata from long tracking ids and release names" do
    rows = argo_obj("v1", "ConfigMap", "big", "amp", tracking_id: "&" * 1500, helm_release: "r" * 3000, instance_label: "i" * 63, app_name: "n" * 63, part_of: "p" * 63)
    world = argo_world.merge("configmaps" => argo_world["configmaps"] + rows)

    post_payload(payload_from_cli(world: world))

    assert_response :created
    row = DriftCheck.find(response.parsed_body["id"]).unmanaged_resources.find_by(name: "amp")
    assert row.metadata["truncated"]
    assert_operator JSON.generate(row.metadata).bytesize, :<=, UnmanagedResource::METADATA_MAX_BYTES
  end
end
