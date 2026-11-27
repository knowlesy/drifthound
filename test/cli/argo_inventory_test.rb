require_relative "argo_cli_helper"

class ArgoInventoryTest < ActiveSupport::TestCase
  include CliTestHelper
  include ArgoCliFixtures

  Argo = DriftHoundCli::Argo

  def kubectl(runner, **opts)
    Argo::Kubectl.new(runner, **opts)
  end

  def inventory(runner, kubectl_opts: {}, **opts)
    defaults = { concurrency: 1, chunk_size: 500, instance_label_key: Argo::DEFAULT_INSTANCE_LABEL, include_secrets: false, exclude_kinds: [] }
    Argo::Inventory.new(kubectl(runner, **kubectl_opts), **defaults.merge(opts))
  end

  def mode(**opts)
    DriftHoundCli::Modes::ArgoUnowned.new(argo_opts(**opts), runner: argo_runner)
  end

  test "the column list matches the order the fixtures are written in" do
    assert_equal ARGO_COLUMNS, Argo::COLUMNS.map(&:first)
    assert_equal 24, Argo::COLUMN_COUNT
  end

  test "the jsonpath template escapes dots in map keys" do
    template = Argo.template

    assert_includes template, '{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
    assert_includes template, '{.metadata.annotations.meta\.helm\.sh/release-name}'
    assert_includes template, '{.metadata.labels.app\.kubernetes\.io/instance}'
    assert template.start_with?("{range .items[*]}")
    assert template.end_with?('{"\n"}{end}')
    assert_equal 24, template.scan('{"\t"}').size + 1
  end

  test "a custom instance label key is escaped and put in the instance column" do
    template = Argo.template("argocd.argoproj.io/instance")

    assert_includes template, '{.metadata.labels.argocd\.argoproj\.io/instance}'
    assert_not_includes template, 'labels.app\.kubernetes\.io/instance'
  end

  test "the template never reads secret data or whole annotations" do
    template = Argo.template

    assert_no_match(/\.data|stringData|last-applied/, template)
    assert_no_match(/annotations\}|labels\}/, template)
  end

  test "parses a literal row in the documented column order" do
    cols = [ "apps/v1", "Deployment", "shop", "web", "u1", "2026-01-01T00:00:00Z", "o1 o2", "web:apps/Deployment:shop/web", "inst", "rel", "relns",
             "prov", "web", "Helm", "web", "part", "chart-1", "aks", "Reconcile", "rbac-defaults", "data logs", "cns", "cname", "" ]
    line = cols.join("\t")

    object = Argo.parse_lines("#{line}\n", "deployments.apps").sole

    assert_equal "apps", object.group
    assert_equal %w[o1 o2], object.owner_uids
    assert_equal "web:apps/Deployment:shop/web", object.tracking_id
    assert_equal "inst", object.installation_id
    assert_equal "rel", object.helm_release
    assert_equal "web", object.instance_label
    assert_equal "Helm", object.managed_by
    assert_equal "rbac-defaults", object.bootstrapping
    assert_equal %w[data logs], object.vct_names.split
    assert_equal "cname", object.claim_name
  end

  test "an empty owner column gives no owners and a core apiVersion gives no group" do
    object = Argo.parse_lines(argo_obj("v1", "Pod", "default", "naked"), "pods").sole

    assert_equal [], object.owner_uids
    assert_equal "", object.group
    assert_not object.cluster_scoped?
  end

  test "a line with the wrong number of columns is fatal" do
    line = argo_obj("v1", "Pod", "default", "naked").chomp.split("\t", -1).first(23).join("\t")

    error = assert_raises(DriftHoundCli::ArgoError) { Argo.parse_lines(line, "pods") }
    assert_match(/23 columns, expected 24/, error.message)
  end

  test "an empty kind, name or uid is fatal" do
    assert_raises(DriftHoundCli::ArgoError) { Argo.parse_lines(argo_row(api_version: "v1", name: "x", uid: "u"), "pods") }
    assert_raises(DriftHoundCli::ArgoError) { Argo.parse_lines(argo_row(api_version: "v1", kind: "Pod", uid: "u"), "pods") }
    assert_raises(DriftHoundCli::ArgoError) { Argo.parse_lines(argo_row(api_version: "v1", kind: "Pod", name: "x"), "pods") }
  end

  test "only Secrets expose a type" do
    assert_equal "helm.sh/release.v1", Argo.parse_lines(argo_obj("v1", "Secret", "a", "b", type: "helm.sh/release.v1"), "secrets").sole.secret_type
    assert_equal "", Argo.parse_lines(argo_obj("v1", "Service", "a", "b", type: "ClusterIP"), "services").sole.secret_type
  end

  test "builds kubectl commands with flags, never environment variables" do
    runner = argo_runner
    inventory(runner, kubectl_opts: { bin: "/opt/kubectl", kubeconfig: "/k/config", context: "prod-aks", timeout: "30s" }, chunk_size: 100).collect

    assert_equal [ "/opt/kubectl", "--kubeconfig", "/k/config", "--context", "prod-aks", "--request-timeout", "30s",
                   "api-resources", "--verbs=list", "--namespaced=true", "-o", "name" ], runner.commands[0]
    assert_equal [ "/opt/kubectl", "--kubeconfig", "/k/config", "--context", "prod-aks", "--request-timeout", "30s",
                   "api-resources", "--verbs=list", "--namespaced=false", "-o", "name" ], runner.commands[1]
    pods = get_calls(runner).find { |cmd| cmd[cmd.index("get") + 1] == "pods" }
    assert_equal [ "/opt/kubectl", "--kubeconfig", "/k/config", "--context", "prod-aks", "--request-timeout", "30s",
                   "get", "pods", "--all-namespaces", "--chunk-size", "100", "-o", "jsonpath=#{Argo.template}" ], pods
    namespaces = get_calls(runner).find { |cmd| cmd[cmd.index("get") + 1] == "namespaces" }
    assert_not_includes namespaces, "--all-namespaces"
    assert_equal({ cmd: pods, chdir: nil }, runner.calls.find { |call| call[:cmd] == pods })
  end

  test "omits context and kubeconfig when not given" do
    runner = argo_runner
    inventory(runner).collect

    assert_equal %w[kubectl --request-timeout 120s api-resources --verbs=list --namespaced=true -o name], runner.commands.first
  end

  test "lists kinds core group first and never lists denied kinds" do
    runner = argo_runner
    result = inventory(runner).collect

    listed = listed_resources(runner)
    assert_equal %w[configmaps namespaces persistentvolumeclaims persistentvolumes pods serviceaccounts services], listed.first(7)
    assert_equal 18, listed.size
    %w[events endpoints nodes secrets controllerrevisions.apps leases.coordination.k8s.io endpointslices.discovery.k8s.io
       apiservices.apiregistration.k8s.io pods.metrics.k8s.io events.events.k8s.io bindings].each do |kind|
      assert_not_includes listed, kind
    end
    assert_equal 18, result.listed
    assert_equal 11, result.denied
  end

  test "secrets are listed only with include_secrets" do
    runner = argo_runner
    result = inventory(runner, include_secrets: true).collect

    assert_includes listed_resources(runner), "secrets"
    assert_equal "helm.sh/release.v1", result.objects.find { |o| o.kind == "Secret" }.secret_type
    assert_equal 10, result.denied
  end

  test "exclude_kinds are honoured and counted" do
    runner = argo_runner
    result = inventory(runner, exclude_kinds: %w[pods customresourcedefinitions.apiextensions.k8s.io]).collect

    assert_not_includes listed_resources(runner), "pods"
    assert_not_includes listed_resources(runner), "customresourcedefinitions.apiextensions.k8s.io"
    assert_equal 2, result.excluded
  end

  test "concurrency 1 and 4 give the same objects in the same order" do
    one = inventory(argo_runner, concurrency: 1).collect.objects.map(&:uid)
    four = inventory(argo_runner, concurrency: 4).collect.objects.map(&:uid)

    assert_equal one, four
    assert_equal one.uniq, one
  end

  test "discovery that fails only for the metrics group continues and is noted" do
    runner = FakeRunner.new
    runner.on(->(cmd) { cmd.include?("--namespaced=true") }, stdout: argo_fixture("api_resources_namespaced.txt"), stderr: argo_fixture("api_resources_partial_stderr.txt"), exit: 1)
    stub_kubectl(runner)

    result = inventory(runner).collect

    assert_equal 1, result.notes.size
    assert_match(/metrics\.k8s\.io/, result.notes.first)
    assert_equal 18, result.listed
  end

  test "discovery that fails for another group is fatal" do
    stderr = "error: unable to retrieve the complete list of server APIs: custom.example.com/v1: the server is currently unable to handle the request"
    runner = FakeRunner.new
    runner.on(->(cmd) { cmd.include?("--namespaced=true") }, stdout: argo_fixture("api_resources_namespaced.txt"), stderr: stderr, exit: 1)
    stub_kubectl(runner)

    error = assert_raises(DriftHoundCli::ArgoError) { inventory(runner).collect }
    assert_match(/api-resources failed/, error.message)
  end

  test "discovery that fails without a recognisable error or output is fatal" do
    runner = FakeRunner.new
    runner.on(->(cmd) { cmd.include?("--namespaced=true") }, stderr: "The connection to the server was refused", exit: 1)
    stub_kubectl(runner)
    assert_raises(DriftHoundCli::ArgoError) { inventory(runner).collect }

    runner = FakeRunner.new
    runner.on(->(cmd) { cmd.include?("--namespaced=true") }, stdout: "pods\n", stderr: "error: something else", exit: 1)
    stub_kubectl(runner)
    assert_raises(DriftHoundCli::ArgoError) { inventory(runner).collect }
  end

  test "forbidden kinds are collected into one error that names the escape hatch" do
    runner = argo_runner(errors: {
      "pods" => [ "Error from server (Forbidden): pods is forbidden: User cannot list resource", 1 ],
      "services" => [ "Error from server (Forbidden): services is forbidden", 1 ]
    })

    error = assert_raises(DriftHoundCli::ArgoError) { inventory(runner).collect }

    assert_match(/forbidden: pods, services\./, error.message)
    assert_match(/--exclude-kind=<resource>/, error.message)
  end

  test "a kind removed between discovery and listing is skipped" do
    runner = argo_runner(errors: { "appprojects.argoproj.io" => [ "error: the server doesn't have a resource type \"appprojects\"", 1 ] })

    result = inventory(runner).collect

    assert_equal [ "appprojects.argoproj.io" ], result.gone
    assert_equal 17, result.listed
  end

  test "any other listing failure is fatal" do
    runner = argo_runner(errors: { "pods" => [ "Unable to connect to the server: EOF", 1 ] })

    error = assert_raises(DriftHoundCli::ArgoError) { inventory(runner).collect }

    assert_match(/kubectl get pods failed/, error.message)
  end

  test "zero listable kinds and zero objects are fatal" do
    runner = FakeRunner.new
    stub_kubectl(runner, namespaced: "events\n", cluster: "nodes\n")
    assert_raises(DriftHoundCli::ArgoError) { inventory(runner).collect }

    runner = argo_runner(world: argo_world.transform_values { "" })
    assert_raises(DriftHoundCli::ArgoError) { inventory(runner).collect }
  end

  test "a missing kubectl gives an error payload" do
    runner = ->(_cmd, chdir: nil) { raise Errno::ENOENT, "kubectl" }

    payload = argo_payload(argo_opts, runner)

    assert_equal "argocd", payload[:source]
    assert_equal "error", payload[:status]
    assert_match(/kubectl was not found/, payload[:raw_output])
    assert_not payload.key?(:unmanaged_resources)
  end

  test "options are parsed into opts and the mode is registered" do
    opts = {}
    DriftHoundCli.build_parser(opts).parse!(%w[--tool=argocd --context=c1 --kubeconfig=/k --kubectl=/bin/kc --cluster-name=prod --argocd-context=hub
                                              --argocd-kubeconfig=/h --argocd-namespace=a1 --argocd-namespace=a2 --argocd-destination=d1
                                              --tracking-method=label --instance-label-key=x.io/i --argocd-installation-id=ii --include-secrets
                                              --include-platform-managed --exclude-kind=a.b --exclude-kind=c --chunk-size=50 --request-timeout=10s --concurrency=2])

    assert_equal DriftHoundCli::Modes::ArgoUnowned, DriftHoundCli::MODES["argocd"]
    assert_equal({ tool: "argocd", kube_context: "c1", kubeconfig: "/k", kubectl: "/bin/kc", cluster_name: "prod", argocd_context: "hub",
                   argocd_kubeconfig: "/h", argo_namespaces: %w[a1 a2], argo_destinations: %w[d1], tracking_method: "label",
                   instance_label_key: "x.io/i", argo_installation_id: "ii", include_secrets: true, include_platform_managed: true,
                   exclude_kinds: %w[a.b c], chunk_size: 50, request_timeout: "10s", concurrency: 2 }, opts)
  end

  test "bad options abort before anything runs" do
    {
      { tracking_method: "magic" } => /Unknown --tracking-method/,
      { argocd_context: "hub" } => /needs at least one --argocd-destination/,
      { concurrency: 0 } => /--concurrency/,
      { concurrency: 17 } => /--concurrency/,
      { chunk_size: 0 } => /--chunk-size/,
      { request_timeout: "soon" } => /--request-timeout/,
      { instance_label_key: "a}{b" } => /--instance-label-key/
    }.each do |bad, message|
      runner = FakeRunner.new
      error = assert_raises(DriftHoundCli::UsageError) { DriftHoundCli::Modes::ArgoUnowned.new(argo_opts(**bad), runner: runner) }
      assert_match message, error.message
      assert_empty runner.calls
    end
  end

  test "argocd-context with a destination is accepted" do
    assert_nothing_raised { mode(argocd_context: "hub", argo_destinations: [ "prod-aks" ]) }
  end
end
