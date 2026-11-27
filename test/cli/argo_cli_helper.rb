require_relative "cli_test_helper"

# Fixtures and a kubectl stub for the Argo CD CLI tests. Object rows are built in
# the CLI's column order, so the fixture world reads as objects rather than as tabs.
module ArgoCliFixtures
  FIXTURE_DIR = Rails.root.join("test/fixtures/files/argocd")

  # The column order of the jsonpath template, written out independently of the CLI
  ARGO_COLUMNS = %i[
    api_version kind namespace name uid created_at owner_refs tracking_id installation_id helm_release helm_release_ns
    provisioned_by instance_label managed_by app_name part_of helm_chart aks_managedby addon_mode bootstrapping
    vct_names claim_ns claim_name type
  ].freeze

  def argo_fixture(name)
    File.read(FIXTURE_DIR.join(name))
  end

  def argo_row(**attrs)
    unknown = attrs.keys - ARGO_COLUMNS
    raise ArgumentError, "unknown column #{unknown.inspect}" unless unknown.empty?

    "#{ARGO_COLUMNS.map { |column| attrs.fetch(column, '').to_s }.join("\t")}\n"
  end

  def argo_uid(kind, namespace, name)
    "uid-#{kind.downcase}-#{namespace}-#{name}"
  end

  # One object as a row: obj("apps/v1", "Deployment", "shop", "web", tracking_id: "...")
  def argo_obj(api_version, kind, namespace, name, **attrs)
    argo_row(api_version: api_version, kind: kind, namespace: namespace, name: name,
             uid: argo_uid(kind, namespace, name), created_at: "2026-01-01T00:00:00Z", **attrs)
  end

  def argo_track(app, group, kind, namespace, name)
    "#{app}:#{group}/#{kind}:#{namespace}/#{name}"
  end

  # Output of `kubectl get <resource> -o jsonpath=...` for every listable kind of the fixture cluster
  def argo_world
    web = argo_uid("Deployment", "shop", "web")
    hand = argo_uid("Deployment", "scratch", "hand")
    web_rs = argo_uid("ReplicaSet", "shop", "web-7d9")
    hand_rs = argo_uid("ReplicaSet", "scratch", "hand-5c")
    {
      "deployments.apps" => [
        # Argo-tracked, with children
        argo_obj("apps/v1", "Deployment", "shop", "web", tracking_id: argo_track("web", "apps", "Deployment", "shop", "web")),
        # installed by hand with `helm install`: Helm markers, no Argo tracking
        argo_obj("apps/v1", "Deployment", "shop", "redis", managed_by: "Helm", instance_label: "redis", app_name: "redis",
                 helm_release: "redis", helm_release_ns: "shop", helm_chart: "redis-19.0.0"),
        # hand-made Deployment with a ReplicaSet and a Pod below it
        argo_obj("apps/v1", "Deployment", "scratch", "hand")
      ].join,
      "replicasets.apps" => [
        argo_obj("apps/v1", "ReplicaSet", "shop", "web-7d9", owner_refs: web),
        argo_obj("apps/v1", "ReplicaSet", "scratch", "hand-5c", owner_refs: hand)
      ].join,
      "statefulsets.apps" => [
        argo_obj("apps/v1", "StatefulSet", "shop", "db", vct_names: "data", tracking_id: argo_track("web", "apps", "StatefulSet", "shop", "db"))
      ].join,
      "pods" => [
        argo_obj("v1", "Pod", "shop", "web-7d9-abc", owner_refs: web_rs),
        argo_obj("v1", "Pod", "scratch", "hand-5c-x", owner_refs: hand_rs),
        # naked Pod
        argo_obj("v1", "Pod", "default", "naked"),
        # mirror Pod owned by a Node that is not listed
        argo_obj("v1", "Pod", "kube-system", "etcd-node1", owner_refs: "uid-node-node1")
      ].join,
      "configmaps" => [
        # applied with kubectl: no markers at all
        argo_obj("v1", "ConfigMap", "default", "settings"),
        argo_obj("v1", "ConfigMap", "shop", "kube-root-ca.crt"),
        # tracking-id of an Application that no longer exists
        argo_obj("v1", "ConfigMap", "shop", "orphan-cm", tracking_id: argo_track("gone", "", "ConfigMap", "shop", "orphan-cm")),
        # Argo-tracked object in a namespace nobody deploys to
        argo_obj("v1", "ConfigMap", "scratch", "tracked", tracking_id: argo_track("web", "", "ConfigMap", "scratch", "tracked")),
        # app in another namespace: instance name team-a_web
        argo_obj("v1", "ConfigMap", "team-a", "team-cfg", tracking_id: argo_track("team-a_web", "", "ConfigMap", "team-a", "team-cfg")),
        argo_obj("v1", "ConfigMap", "kube-system", "coredns-custom", addon_mode: "EnsureExists"),
        argo_obj("v1", "ConfigMap", "argocd", "argocd-cm"),
        argo_obj("v1", "ConfigMap", "managed-ns", "settings")
      ].join,
      "serviceaccounts" => argo_obj("v1", "ServiceAccount", "shop", "default"),
      "services" => argo_obj("v1", "Service", "default", "kubernetes"),
      "persistentvolumeclaims" => argo_obj("v1", "PersistentVolumeClaim", "shop", "data-db-0"),
      "persistentvolumes" => argo_obj("v1", "PersistentVolume", "", "pvc-123", provisioned_by: "disk.csi.azure.com", claim_ns: "shop", claim_name: "data-db-0"),
      "applications.argoproj.io" => [
        argo_obj("argoproj.io/v1alpha1", "Application", "argocd", "root"),
        argo_obj("argoproj.io/v1alpha1", "Application", "argocd", "web", tracking_id: argo_track("root", "argoproj.io", "Application", "argocd", "web")),
        argo_obj("argoproj.io/v1alpha1", "Application", "team-a", "web", tracking_id: argo_track("root", "argoproj.io", "Application", "team-a", "web")),
        argo_obj("argoproj.io/v1alpha1", "Application", "argocd", "widgets", tracking_id: argo_track("root", "argoproj.io", "Application", "argocd", "widgets"))
      ].join,
      "appprojects.argoproj.io" => argo_obj("argoproj.io/v1alpha1", "AppProject", "argocd", "default"),
      "roles.rbac.authorization.k8s.io" => "",
      "namespaces" => [
        argo_obj("v1", "Namespace", "", "default"),
        argo_obj("v1", "Namespace", "", "kube-system"),
        argo_obj("v1", "Namespace", "", "shop"),
        argo_obj("v1", "Namespace", "", "team-a"),
        argo_obj("v1", "Namespace", "", "scratch"),
        argo_obj("v1", "Namespace", "", "argocd"),
        argo_obj("v1", "Namespace", "", "managed-ns", aks_managedby: "aks")
      ].join,
      "clusterroles.rbac.authorization.k8s.io" => [
        argo_obj("rbac.authorization.k8s.io/v1", "ClusterRole", "", "system:foo"),
        argo_obj("rbac.authorization.k8s.io/v1", "ClusterRole", "", "view", bootstrapping: "rbac-defaults"),
        argo_obj("rbac.authorization.k8s.io/v1", "ClusterRole", "", "hand-made")
      ].join,
      "clusterrolebindings.rbac.authorization.k8s.io" => "",
      "customresourcedefinitions.apiextensions.k8s.io" => [
        # listed by an Application but without a tracking marker
        argo_obj("apiextensions.k8s.io/v1", "CustomResourceDefinition", "", "widgets.example.com"),
        argo_obj("apiextensions.k8s.io/v1", "CustomResourceDefinition", "", "foo.example.com"),
        argo_obj("apiextensions.k8s.io/v1", "CustomResourceDefinition", "", "applications.argoproj.io")
      ].join,
      "storageclasses.storage.k8s.io" => argo_obj("storage.k8s.io/v1", "StorageClass", "", "custom-fast"),
      "priorityclasses.scheduling.k8s.io" => "",
      "secrets" => argo_obj("v1", "Secret", "shop", "sh.helm.release.v1.redis.v1", type: "helm.sh/release.v1")
    }
  end

  # Answers every kubectl call of the fixture cluster. errors: { "pods" => [stderr, exit] }
  def stub_kubectl(runner, world: argo_world, applications: nil, errors: {}, namespaced: argo_fixture("api_resources_namespaced.txt"),
                   cluster: argo_fixture("api_resources_cluster.txt"), context: "prod-aks")
    applications ||= argo_fixture("applications.json") if FIXTURE_DIR.join("applications.json").exist?
    runner.on(->(cmd) { cmd.include?("api-resources") && cmd.include?("--namespaced=true") }) { [ namespaced, "", 0 ] }
    runner.on(->(cmd) { cmd.include?("api-resources") && cmd.include?("--namespaced=false") }) { [ cluster, "", 0 ] }
    runner.on(->(cmd) { cmd.include?("config") && cmd.include?("current-context") }) { [ "#{context}\n", "", 0 ] }
    runner.on(->(cmd) { cmd.include?("get") && cmd.last == "json" }) { [ applications.to_s, "", 0 ] }
    runner.on(->(cmd) { cmd.include?("get") && cmd.any? { |arg| arg.start_with?("jsonpath=") } }) do |cmd, _|
      resource = cmd[cmd.index("get") + 1]
      stderr, code = errors[resource]
      if stderr
        [ "", stderr, code || 1 ]
      else
        [ world.fetch(resource) { raise "no fixture for #{resource}" }, "", 0 ]
      end
    end
  end

  def argo_opts(**extra)
    { tool: "argocd", project: "platform", environment: "prod-aks-argocd", token: "tok", api_url: "http://dh.test",
      kube_context: "prod-aks", concurrency: 1 }.merge(extra)
  end

  def argo_runner(**stub)
    CliTestHelper::FakeRunner.new.tap { |runner| stub_kubectl(runner, **stub) }
  end

  def argo_payload(opts, runner)
    payload = nil
    capture_io { payload = DriftHoundCli::Modes::ArgoUnowned.new(opts, runner: runner).build_payload }
    payload
  end

  def get_calls(runner)
    runner.commands.select { |cmd| cmd.include?("get") && cmd.any? { |arg| arg.start_with?("jsonpath=") } }
  end

  def listed_resources(runner)
    get_calls(runner).map { |cmd| cmd[cmd.index("get") + 1] }
  end
end
