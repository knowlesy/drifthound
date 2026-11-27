require_relative "argo_cli_helper"

class ArgoUnownedTest < ActiveSupport::TestCase
  include CliTestHelper
  include ArgoCliFixtures

  # What the fixture cluster should report with the default flags
  EXPECTED = %w[
    apiextensions.k8s.io/CustomResourceDefinition/_cluster/applications.argoproj.io
    apiextensions.k8s.io/CustomResourceDefinition/_cluster/foo.example.com
    apps/Deployment/scratch/hand
    apps/Deployment/shop/redis
    apps/Deployment/shop/web2
    argoproj.io/AppProject/argocd/default
    argoproj.io/Application/argocd/root
    core/ConfigMap/default/settings
    core/ConfigMap/shop/kube-root-ca.crt
    core/ConfigMap/shop/orphan-cm
    core/Namespace/_cluster/default
    core/Namespace/_cluster/kube-system
    core/Namespace/_cluster/scratch
    core/Pod/default/naked
    core/Service/default/kubernetes
    core/ServiceAccount/shop/default
    rbac.authorization.k8s.io/ClusterRole/_cluster/hand-made
    rbac.authorization.k8s.io/ClusterRole/_cluster/system:foo
    storage.k8s.io/StorageClass/_cluster/custom-fast
  ].sort_by(&:downcase).freeze

  def payload_for(opts = {}, stub = {})
    runner = argo_runner(**stub)
    [ argo_payload(argo_opts(**opts), runner), runner ]
  end

  def identifiers(payload)
    payload[:unmanaged_resources].map { |item| item[:identifier] }
  end

  def item(payload, identifier)
    payload[:unmanaged_resources].find { |i| i[:identifier] == identifier } || flunk("#{identifier} was not reported")
  end

  def world_with(extra = {})
    world = argo_world
    extra.each { |resource, rows| world[resource] = world.fetch(resource) + rows }
    world
  end

  test "reports exactly the objects nothing owns, sorted" do
    payload, = payload_for

    assert_equal "argocd", payload[:source]
    assert_equal "ok", payload[:status]
    assert_equal EXPECTED, identifiers(payload)
    assert_kind_of Float, payload[:duration]
    assert_not payload.key?(:directory)
  end

  test "the scratch namespace is reported and the application namespaces are not" do
    ids = identifiers(payload_for.first)

    assert_includes ids, "core/Namespace/_cluster/scratch"
    assert_not_includes ids, "core/Namespace/_cluster/shop"
    assert_not_includes ids, "core/Namespace/_cluster/team-a"
    assert_not_includes ids, "core/Namespace/_cluster/argocd"
    assert_not_includes ids, "core/ConfigMap/scratch/tracked"
  end

  test "children are counted on their root and never reported" do
    payload, = payload_for

    assert_equal 2, item(payload, "apps/Deployment/scratch/hand")[:metadata][:dependents]
    ids = identifiers(payload)
    assert(ids.none? { |id| id.include?("ReplicaSet") })
    assert_not_includes ids, "core/Pod/scratch/hand-5c-x"
    assert_not_includes ids, "core/Pod/kube-system/etcd-node1"
    assert_not item(payload, "apps/Deployment/shop/redis")[:metadata].key?(:dependents)
  end

  test "an owner that is not listed still makes an object a dependent" do
    payload, = payload_for

    assert_match(/1 with an owner that is not listed/, payload[:raw_output])
  end

  test "an ownership cycle does not hang or report" do
    rows = argo_obj("v1", "ConfigMap", "loop", "a", owner_refs: argo_uid("ConfigMap", "loop", "b")) +
           argo_obj("v1", "ConfigMap", "loop", "b", owner_refs: argo_uid("ConfigMap", "loop", "a"))

    payload, = payload_for({}, world: world_with("configmaps" => rows))

    assert_equal EXPECTED, identifiers(payload)
  end

  test "the Argo CD control plane is skipped but hand-made Applications and projects are reported" do
    ids = identifiers(payload_for.first)

    assert_not_includes ids, "core/ConfigMap/argocd/argocd-cm"
    assert_includes ids, "argoproj.io/Application/argocd/root"
    assert_includes ids, "argoproj.io/AppProject/argocd/default"
  end

  test "platform managed objects are skipped and --include-platform-managed reports them" do
    skipped = %w[core/ConfigMap/kube-system/coredns-custom core/Namespace/_cluster/managed-ns core/ConfigMap/managed-ns/settings
                 rbac.authorization.k8s.io/ClusterRole/_cluster/view]

    ids = identifiers(payload_for.first)
    skipped.each { |id| assert_not_includes ids, id }

    all = identifiers(payload_for(include_platform_managed: true).first)
    assert_equal (EXPECTED + skipped).sort_by(&:downcase), all
  end

  test "an AKS managed Helm release is platform managed" do
    rows = argo_obj("apps/v1", "Deployment", "shop", "aks-thing", helm_release: "aks-managed-foo")

    ids = identifiers(payload_for({}, world: world_with("deployments.apps" => rows)).first)

    assert_not_includes ids, "apps/Deployment/shop/aks-thing"
  end

  test "dynamically provisioned storage is derived from its owner" do
    rows = argo_obj("v1", "PersistentVolumeClaim", "shop", "logs-db-0") + argo_obj("v1", "PersistentVolumeClaim", "shop", "data-db-x")
    pvs = argo_obj("v1", "PersistentVolume", "", "manual-pv") + argo_obj("v1", "PersistentVolume", "", "unbound", provisioned_by: "disk.csi.azure.com")
    payload, = payload_for({}, world: world_with("persistentvolumeclaims" => rows, "persistentvolumes" => pvs))

    ids = identifiers(payload)
    assert_not_includes ids, "core/PersistentVolumeClaim/shop/data-db-0"
    assert_not_includes ids, "core/PersistentVolume/_cluster/pvc-123"
    assert_includes ids, "core/PersistentVolumeClaim/shop/logs-db-0"
    assert_includes ids, "core/PersistentVolumeClaim/shop/data-db-x"
    assert_includes ids, "core/PersistentVolume/_cluster/manual-pv"
    assert_includes ids, "core/PersistentVolume/_cluster/unbound"
  end

  test "items carry the documented fields and metadata" do
    payload, = payload_for
    redis = item(payload, "apps/Deployment/shop/redis")

    assert_equal "Deployment.apps", redis[:resource_type]
    assert_equal "redis", redis[:name]
    assert_equal "shop", redis[:scope]
    assert_equal "prod-aks", redis[:location]
    assert_equal({ api_version: "apps/v1", uid: "uid-deployment-shop-redis", created_at: "2026-01-01T00:00:00Z", reason: "untracked",
                   managed_by: "Helm", helm_release: "redis", helm_release_namespace: "shop", helm_chart: "redis-19.0.0",
                   labels: { "app.kubernetes.io/instance" => "redis", "app.kubernetes.io/name" => "redis" } }, redis[:metadata])
    assert_equal "Pod", item(payload, "core/Pod/default/naked")[:resource_type]
    assert_equal "ConfigMap", item(payload, "core/ConfigMap/default/settings")[:resource_type]
    assert_equal "unknown-application", item(payload, "core/ConfigMap/shop/orphan-cm")[:metadata][:reason]
    assert_equal "gone:/ConfigMap:shop/orphan-cm", item(payload, "core/ConfigMap/shop/orphan-cm")[:metadata][:tracking_id]
  end

  test "cluster-scoped objects have no scope" do
    payload, = payload_for

    cluster_role = item(payload, "rbac.authorization.k8s.io/ClusterRole/_cluster/hand-made")
    assert_nil cluster_role[:scope]
    assert_equal "ClusterRole.rbac.authorization.k8s.io", cluster_role[:resource_type]
    assert_nil item(payload, "core/Namespace/_cluster/scratch")[:scope]
  end

  test "the location is the cluster name, the context, or the current context" do
    assert_equal "prod", payload_for(cluster_name: "prod").first[:unmanaged_resources].first[:location]
    assert_equal "prod-aks", payload_for.first[:unmanaged_resources].first[:location]

    from_config, runner = payload_for(kube_context: nil)
    assert_equal "prod-aks", from_config[:unmanaged_resources].first[:location]
    assert(runner.commands.any? { |cmd| cmd.last(2) == %w[config current-context] })
  end

  test "without a context or a kubeconfig the cluster is in-cluster" do
    runner = FakeRunner.new
    stub_kubectl(runner)
    runner.instance_variable_get(:@routes).unshift([ ->(cmd) { cmd.last(2) == %w[config current-context] }, ->(_cmd, _chdir) { [ "", "error: current-context is not set", 1 ] } ])

    payload = argo_payload(argo_opts(kube_context: nil), runner)

    assert_equal "in-cluster", payload[:unmanaged_resources].first[:location]
    assert_not(runner.commands.any? { |cmd| cmd.include?("--context") })
  end

  test "a cluster name is cut to the server limit" do
    payload, = payload_for(cluster_name: "c" * 200)

    assert_equal 128, payload[:unmanaged_resources].first[:location].length
  end

  test "metadata over the size guard drops labels first, then the tracking id" do
    long_labels = argo_obj("v1", "ConfigMap", "big", "mid", tracking_id: "x" * 1450, instance_label: "i" * 63, app_name: "n" * 63, part_of: "p" * 63)
    huge = argo_obj("v1", "ConfigMap", "big", "huge", tracking_id: "y" * 1900, instance_label: "i")
    payload, = payload_for({}, world: world_with("configmaps" => long_labels + huge))

    mid = item(payload, "core/ConfigMap/big/mid")[:metadata]
    assert mid[:truncated]
    assert_not mid.key?(:labels)
    assert_equal 1450, mid[:tracking_id].length
    huge_meta = item(payload, "core/ConfigMap/big/huge")[:metadata]
    assert huge_meta[:truncated]
    assert_not huge_meta.key?(:tracking_id)
    assert_operator huge_meta.to_json.bytesize, :<=, 1800
  end

  test "NUL bytes are removed from strings sent to the server" do
    rows = argo_obj("v1", "ConfigMap", "nul", "a", helm_release: "re\u0000lease")

    payload, = payload_for({}, world: world_with("configmaps" => rows))

    assert_equal "release", item(payload, "core/ConfigMap/nul/a")[:metadata][:helm_release]
  end

  test "more than 5000 unowned objects are truncated and noted" do
    rows = Array.new(5001) { |i| argo_obj("v1", "Pod", "bulk", format("p%05d", i)) }.join

    payload, = payload_for({}, world: world_with("pods" => rows))

    assert_equal 5000, payload[:unmanaged_resources].size
    assert_match(/Only the first 5000 are reported; \d+ more were dropped\./, payload[:raw_output])
    assert_equal identifiers(payload), identifiers(payload).sort_by(&:downcase)
    assert_match(/\.\.\. and \d+ more/, payload[:raw_output])
  end

  test "an object served under two groups is reported once, from the first group" do
    ext = argo_obj("extensions/v1beta1", "Ingress", "shop", "old").sub("uid-ingress-shop-old", "uid-same")
    net = argo_obj("networking.k8s.io/v1", "Ingress", "shop", "old").sub("uid-ingress-shop-old", "uid-same")
    runner = FakeRunner.new
    stub_kubectl(runner, world: argo_world.merge("ingresses.extensions" => ext, "ingresses.networking.k8s.io" => net),
                         namespaced: "#{argo_fixture('api_resources_namespaced.txt')}ingresses.networking.k8s.io\ningresses.extensions\n")

    payload = argo_payload(argo_opts, runner)

    assert_equal [ "extensions/Ingress/shop/old" ], identifiers(payload).grep(/Ingress/)
    assert_match(/duplicates dropped: 1/, payload[:raw_output])
  end

  test "the installation id option limits what counts as tracked" do
    payload, = payload_for(argo_installation_id: "prod")

    assert_equal "installation-id-mismatch", item(payload, "core/ConfigMap/scratch/tracked")[:metadata][:reason]
    # still owned: an in-scope Application lists it in status.resources
    assert_not_includes identifiers(payload), "apps/Deployment/shop/web"
  end

  test "label tracking owns objects labelled with a known application" do
    rows = argo_obj("v1", "ConfigMap", "shop", "by-label", instance_label: "web") + argo_obj("v1", "ConfigMap", "shop", "by-helm", instance_label: "redis")

    ids = identifiers(payload_for({ tracking_method: "label" }, { world: world_with("configmaps" => rows) }).first)

    assert_not_includes ids, "core/ConfigMap/shop/by-label"
    assert_includes ids, "core/ConfigMap/shop/by-helm"
  end

  test "secrets are reported only with --include-secrets, as a name and a type" do
    assert_not_includes identifiers(payload_for.first), "core/Secret/shop/sh.helm.release.v1.redis.v1"

    payload, runner = payload_for(include_secrets: true)
    secret = item(payload, "core/Secret/shop/sh.helm.release.v1.redis.v1")

    assert_equal "helm.sh/release.v1", secret[:metadata][:secret_type]
    assert_equal "Secret", secret[:resource_type]
    projections = get_calls(runner).map { |cmd| cmd.find { |arg| arg.start_with?("jsonpath=") } }
    assert(projections.any? { |t| t.include?("{.type}") })
    projections.each { |t| assert_no_match(/\.data|stringData/, t) }
    assert_no_match(/"data"/, payload.to_json)
  end

  test "raw_output summarises the run" do
    output = payload_for.first[:raw_output]

    assert_match(/^Cluster: prod-aks$/, output)
    assert_match(/Applications in scope: 4/, output)
    assert_match(/Kinds listed: 18; skipped by default: 11; excluded with --exclude-kind: 0/, output)
    assert_match(/Objects scanned: 42 /, output)
    assert_match(/7 tracked, 1 listed by an Application, 3 Application namespaces/, output)
    assert_match(/Unowned objects: 19$/, output)
    assert_match(/Helm releases without Argo CD: redis \(1\)/, output)
    assert_includes output, "apps/Deployment/shop/redis"
  end

  test "the directory is only sent when --dir is given" do
    assert_equal "infra", payload_for(dir: "infra").first[:directory]
  end

  test "error payloads carry no list" do
    [ { errors: { "pods" => [ "Unable to connect to the server", 1 ] } }, { applications: argo_fixture("applications_empty.json") } ].each do |stub|
      payload, = payload_for({}, **stub)

      assert_equal "error", payload[:status]
      assert_not payload.key?(:unmanaged_resources)
      assert_match(/Argo CD unowned resource check failed/, payload[:raw_output])
    end
  end

  test "concurrency does not change the result" do
    assert_equal identifiers(payload_for.first), identifiers(payload_for(concurrency: 4).first)
  end
end
