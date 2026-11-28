require_relative "argo_cli_helper"

class ArgoTrackingTest < ActiveSupport::TestCase
  include CliTestHelper
  include ArgoCliFixtures

  Argo = DriftHoundCli::Argo

  def owner(object, method: "annotation", installation_id: nil, apps: argo_apps)
    Argo::Tracking.owner(object, apps: apps, method: method, installation_id: installation_id)
  end

  def tracked(kind: "Deployment", group: "apps", namespace: "shop", name: "web", app: "web", **extra)
    version = group.empty? ? "v1" : "#{group}/v1"
    argo_kube(version, kind, namespace, name, tracking_id: argo_track(app, group, kind, namespace, name), **extra)
  end

  test "a valid tracking annotation of a known application is owned" do
    verdict = owner(tracked)

    assert verdict.owned?
    assert_nil verdict.reason
    assert_not verdict.group_mismatch
  end

  test "an object without markers is untracked" do
    verdict = owner(argo_kube("v1", "ConfigMap", "default", "settings"))

    assert_not verdict.owned?
    assert_equal "untracked", verdict.reason
  end

  test "an invalid tracking id format is reported as such" do
    [ "web", "web:apps/Deployment", "web:apps-Deployment:shop/web", "web:apps/Deployment:shop", ":apps/Deployment:shop/web", "web:apps/Deployment:shop/" ].each do |bad|
      verdict = owner(argo_kube("apps/v1", "Deployment", "shop", "web", tracking_id: bad))

      assert_equal "invalid-tracking-id", verdict.reason, bad
    end
  end

  test "a tracking id that points at another object is not self-referenced" do
    assert_equal "not-self-referenced", owner(tracked(name: "web", app: "web").tap { |o| o.name = "copy" }).reason
    assert_equal "not-self-referenced", owner(tracked.tap { |o| o.kind = "StatefulSet" }).reason
    assert_equal "not-self-referenced", owner(tracked.tap { |o| o.namespace = "other" }).reason
  end

  test "a group mismatch is tolerated and flagged" do
    object = argo_kube("networking.k8s.io/v1", "Ingress", "shop", "web", tracking_id: argo_track("web", "extensions", "Ingress", "shop", "web"))

    verdict = owner(object)

    assert verdict.owned?
    assert verdict.group_mismatch
  end

  test "a cluster-scoped object carries the destination namespace in the annotation" do
    object = argo_kube("rbac.authorization.k8s.io/v1", "ClusterRole", "", "reader", tracking_id: "web:rbac.authorization.k8s.io/ClusterRole:shop/reader")

    assert owner(object).owned?
  end

  test "an unknown application name is reported" do
    verdict = owner(tracked(app: "deleted-app"))

    assert_equal "unknown-application", verdict.reason
  end

  test "applications in another namespace are named namespace_name" do
    apps = argo_apps

    assert_equal Set.new(%w[root web team-a_web widgets]), apps.instance_names
    assert owner(tracked(kind: "ConfigMap", group: "", namespace: "team-a", name: "team-cfg", app: "team-a_web"), apps: apps).owned?
    assert_equal "unknown-application", owner(tracked(kind: "ConfigMap", group: "", namespace: "team-a", name: "team-cfg", app: "team-a"), apps: apps).reason
  end

  test "every control plane namespace names applications without a prefix" do
    apps = argo_apps(namespaces: %w[argocd team-a])

    assert_equal Set.new(%w[root web widgets]), apps.instance_names
  end

  test "the installation id must match when one is configured" do
    assert owner(tracked(installation_id: "prod"), installation_id: "prod").owned?
    assert_equal "installation-id-mismatch", owner(tracked(installation_id: "other"), installation_id: "prod").reason
    assert_equal "installation-id-mismatch", owner(tracked, installation_id: "prod").reason
    assert owner(tracked(installation_id: "anything")).owned?
  end

  test "label mode is owned only by a known application name" do
    apps = argo_apps

    assert owner(argo_kube("apps/v1", "Deployment", "shop", "web", instance_label: "web"), method: "label", apps: apps).owned?
    helm = argo_kube("apps/v1", "Deployment", "shop", "redis", instance_label: "redis", managed_by: "Helm")
    assert_equal "unknown-application", owner(helm, method: "label", apps: apps).reason
    assert_equal "untracked", owner(argo_kube("v1", "ConfigMap", "a", "b"), method: "label", apps: apps).reason
  end

  test "label mode does no self-reference check and cuts names to 63 characters" do
    long = "a" * 70
    items = [ { "metadata" => { "name" => long, "namespace" => "argocd" }, "spec" => { "destination" => { "server" => "in-cluster" } } } ]
    apps = Argo::Applications.parse(JSON.generate(items: items), destinations: %w[in-cluster], argo_namespaces: [ "argocd" ])

    assert owner(argo_kube("v1", "ConfigMap", "a", "b", instance_label: "a" * 63), method: "label", apps: apps).owned?
    assert_equal "a" * 62, Argo::Applications.label_value("#{'a' * 62}-x-y")[0, 62]
    assert_equal "a" * 5, Argo::Applications.label_value("aaaaa--__")
  end

  test "annotation modes ignore the instance label" do
    helm = argo_kube("apps/v1", "Deployment", "shop", "web", instance_label: "web")

    assert_equal "untracked", owner(helm, method: "annotation").reason
    assert_equal "untracked", owner(helm, method: "annotation+label").reason
    assert owner(tracked, method: "annotation+label").owned?
  end

  test "status.resources of in-scope applications list objects without a marker" do
    apps = argo_apps

    assert apps.lists?(argo_kube("apiextensions.k8s.io/v1", "CustomResourceDefinition", "", "widgets.example.com"))
    assert apps.lists?(argo_kube("apps/v1", "Deployment", "shop", "web"))
    assert apps.lists?(argo_kube("apps/v1", "Deployment", "SHOP", "WEB"))
    assert_not apps.lists?(argo_kube("apps/v1", "Deployment", "other", "web"))
    assert_not apps.lists?(argo_kube("apiextensions.k8s.io/v1", "CustomResourceDefinition", "", "foo.example.com"))
  end

  test "resources of applications that deploy to another cluster are not used" do
    assert_not argo_apps.lists?(argo_kube("apps/v1", "Deployment", "shop", "web2"))
  end

  test "destination namespaces of in-scope applications only" do
    apps = argo_apps

    assert apps.destination_namespace?("shop")
    assert apps.destination_namespace?("team-a")
    assert apps.destination_namespace?("argocd")
    assert_equal 4, apps.in_scope_count
  end

  test "destinations match by server or name, and an explicit list replaces the defaults" do
    remote = argo_apps(destinations: [ "https://other-cluster:443/" ])

    assert_equal 1, remote.in_scope_count
    assert remote.lists?(argo_kube("apps/v1", "Deployment", "shop", "web2"))
    assert_equal Set.new(%w[web2-remote]), remote.instance_names
    assert_equal 1, argo_apps(destinations: [ "in-cluster" ]).in_scope_count
  end

  test "no applications in scope is an error that lists the destinations seen" do
    error = assert_raises(DriftHoundCli::ArgoError) { argo_apps("applications_other_dest_only.json") }
    assert_match(%r{Applications target: https://other-cluster:443}, error.message)

    assert_raises(DriftHoundCli::ArgoError) { argo_apps("applications_empty.json") }
    assert_raises(DriftHoundCli::ArgoError) { Argo::Applications.parse("not json", destinations: [ "x" ], argo_namespaces: []) }
  end

  test "the mode reports the empty scope as an error payload before listing anything" do
    runner = argo_runner(applications: argo_fixture("applications_other_dest_only.json"))

    payload = argo_payload(argo_opts, runner)

    assert_equal "error", payload[:status]
    assert_match(/no Argo CD Application deploys to/, payload[:raw_output])
    assert_not payload.key?(:unmanaged_resources)
    assert_empty get_calls(runner)
  end

  test "a hub cluster is read with its own context and the destination filter" do
    runner = argo_runner
    opts = argo_opts(argocd_context: "hub", argocd_kubeconfig: "/hub/config", argo_destinations: [ "in-cluster" ])

    argo_payload(opts, runner)

    command = runner.commands.find { |cmd| cmd.last == "json" }
    assert_equal %w[kubectl --kubeconfig /hub/config --context hub --request-timeout 120s get applications.argoproj.io --all-namespaces -o json], command
    assert(runner.commands.any? { |cmd| cmd.include?("--namespaced=true") && cmd.include?("prod-aks") })
  end

  test "missing Argo CD CRDs are named in the error" do
    runner = FakeRunner.new
    runner.on(->(cmd) { cmd.last == "json" }, stderr: %(error: the server doesn't have a resource type "applications"), exit: 1)
    stub_kubectl(runner)

    payload = argo_payload(argo_opts, runner)

    assert_match(/Argo CD CRDs not found in prod-aks/, payload[:raw_output])
  end

  test "annotation tracking against a label-tracked cluster fails closed" do
    world = argo_world.transform_values { |rows| rows.gsub(/\t[a-z0-9_-]+:[a-zA-Z.]*\/[A-Za-z]+:[a-z0-9-]*\/[^\t]+\t/, "\t\t") }
    world["deployments.apps"] += argo_obj("apps/v1", "Deployment", "shop", "labelled", instance_label: "web")
    runner = argo_runner(world: world)

    payload = argo_payload(argo_opts, runner)

    assert_equal "error", payload[:status]
    assert_match(/--tracking-method=label/, payload[:raw_output])
  end

  test "the heuristic stays quiet when tracking annotations exist or label mode is chosen" do
    apps = argo_apps
    labelled = [ argo_kube("v1", "ConfigMap", "a", "b", instance_label: "web") ]

    assert_raises(DriftHoundCli::ArgoError) { Argo::Tracking.check_method!(labelled, apps, "annotation") }
    assert_nil Argo::Tracking.check_method!(labelled, apps, "label")
    assert_nil Argo::Tracking.check_method!(labelled + [ tracked ], apps, "annotation")
    assert_nil Argo::Tracking.check_method!([ argo_kube("v1", "ConfigMap", "a", "b", instance_label: "redis") ], apps, "annotation")
  end
end
