require_relative "cli_test_helper"

class AzureUnmanagedTest < ActiveSupport::TestCase
  include CliTestHelper
  include AzureCliFixtures

  RG_MANUAL = "/subscriptions/#{S1}/resourceGroups/rg-manual".freeze
  STMANUAL = "/subscriptions/#{S1}/resourceGroups/rg-app/providers/Microsoft.Storage/storageAccounts/stmanual".freeze
  KV_APP = "/subscriptions/#{S2}/resourceGroups/rg-sec/providers/Microsoft.KeyVault/vaults/kv-app".freeze
  NETWORK_WATCHER = "/subscriptions/#{S1}/resourceGroups/NetworkWatcherRG".freeze
  MC_RG = "/subscriptions/#{S1}/resourceGroups/MC_rg-app_aks-app_westeurope".freeze
  MC_LB = "#{MC_RG}/providers/Microsoft.Network/loadBalancers/kubernetes".freeze
  OSDISK = "/subscriptions/#{S1}/resourceGroups/rg-app/providers/Microsoft.Compute/disks/osdisk1".freeze

  def az_runner
    FakeRunner.new.tap { |runner| stub_az(runner) }
  end

  def graph_calls(runner)
    runner.commands.select { |cmd| cmd.first(3) == %w[az graph query] }
  end

  test "reports resources missing from state as an ok check with a list" do
    payload = azure_payload(azure_opts, az_runner)

    assert_equal "azure", payload[:source]
    assert_equal "ok", payload[:status]
    assert_equal [ RG_MANUAL, STMANUAL, KV_APP, NETWORK_WATCHER ].sort_by(&:downcase), identifiers(payload)
    assert_not payload.key?(:directory)
    assert_kind_of Float, payload[:duration]
  end

  test "items carry the documented fields" do
    item = azure_payload(azure_opts, az_runner)[:unmanaged_resources].find { |i| i[:identifier] == STMANUAL }

    assert_equal "microsoft.storage/storageaccounts", item[:resource_type]
    assert_equal "stmanual", item[:name]
    assert_equal "rg-app", item[:scope]
    assert_equal "westeurope", item[:location]
    assert_equal({ subscription_id: S1, managed_by: "", tags: { "owner" => "alice" } }, item[:metadata])
  end

  test "pages through the skip token and queries the subscriptions first" do
    runner = az_runner
    azure_payload(azure_opts, runner)

    calls = graph_calls(runner)
    assert_equal 3, calls.size
    assert_equal DriftHoundCli::Modes::AzureUnmanaged::SUBSCRIPTIONS_QUERY, calls[0][calls[0].index("-q") + 1]
    assert_not_includes calls[1], "--skip-token"
    assert_equal "FAKE-SKIP-TOKEN-PAGE-2", calls[2][calls[2].index("--skip-token") + 1]
    assert_equal [ S1, S2 ], calls[1][(calls[1].index("--subscriptions") + 1)..(calls[1].index("--output") - 1)]
    assert_equal "1000", calls[1][calls[1].index("--first") + 1]
  end

  test "accepts skipToken, a bare array and a missing token" do
    bare = JSON.generate(JSON.parse(fixture_text("arg_page2.json"))["data"])
    camel = JSON.generate("data" => JSON.parse(fixture_text("arg_page1.json"))["data"], "skipToken" => "t2")
    runner = FakeRunner.new { stub_az(self, page1: camel, page2: bare) }

    payload = azure_payload(azure_opts, runner)

    assert_equal "ok", payload[:status]
    assert_includes identifiers(payload), KV_APP
  end

  test "matches managed ids case-insensitively and ignores trailing slashes" do
    ids = identifiers(azure_payload(azure_opts, az_runner))

    assert_not_includes ids, "/subscriptions/#{S1}/resourceGroups/rg-app"
    assert_not_includes ids, "/subscriptions/#{S1}/resourceGroups/rg-app/providers/Microsoft.Storage/storageAccounts/stapp"
    assert_not_includes ids, "/subscriptions/#{S2}/resourceGroups/rg-sec/providers/Microsoft.Network/virtualNetworks/vnet-hub"
  end

  test "data sources do not make a resource managed" do
    ids = identifiers(azure_payload(azure_opts, az_runner))

    assert_includes ids, KV_APP
    assert_includes ids, RG_MANUAL
  end

  test "composite state ids are not split" do
    assert_includes identifiers(azure_payload(azure_opts, az_runner)), STMANUAL
  end

  test "non-ARM ids in state are ignored" do
    ids = DriftHoundCli::TerraformState.managed_ids(JSON.parse(fixture_text("tf_show.json")))

    assert_equal 4, ids.size
    assert ids.all? { |id| id.start_with?("/subscriptions/") && id == id.downcase }
  end

  test "state pull layout is read and combined with other sources" do
    runner = az_runner
    runner.on([ "terraform", "state", "pull" ], stdout: fixture_text("tf_state_pull.json"))

    payload = azure_payload(azure_opts(state_files: [ fixture_path("tf_show.json") ], state_dirs: [ "stacks/sec" ]), runner)

    assert_equal "ok", payload[:status]
    assert_equal identifiers(azure_payload(azure_opts, az_runner)), identifiers(payload)
    assert_includes runner.commands, %w[terraform state pull]
    assert_equal "stacks/sec", runner.calls.find { |c| c[:cmd].include?("pull") }[:chdir]
    assert_includes identifiers(payload), STMANUAL
  end

  test "state pull alone supplies the managed set" do
    runner = az_runner
    runner.on([ "tofu", "state", "pull" ], stdout: fixture_text("tf_state_pull.json"))

    payload = azure_payload(azure_opts(state_files: [], state_dirs: [ "d" ], state_tool: "tofu"), runner)

    assert_equal "ok", payload[:status]
    ids = identifiers(payload)
    assert_not_includes ids, "/subscriptions/#{S2}/resourceGroups/rg-sec"
    assert_includes ids, "/subscriptions/#{S1}/resourceGroups/rg-app"
  end

  test "managedBy rows and resources in managed resource groups are skipped by default" do
    payload = azure_payload(azure_opts, az_runner)
    ids = identifiers(payload)

    [ MC_RG, MC_LB, OSDISK ].each { |id| assert_not_includes ids, id }
    assert_match(/Skipped \(managedBy or managed resource group\): 3/, payload[:raw_output])
  end

  test "include-managed-by reports them" do
    payload = azure_payload(azure_opts(include_managed_by: true), az_runner)

    [ MC_RG, MC_LB, OSDISK ].each { |id| assert_includes identifiers(payload), id }
    assert_equal 7, payload[:unmanaged_resources].size
    assert_no_match(/Skipped/, payload[:raw_output])
  end

  test "resource group rows are reported like other resources" do
    item = azure_payload(azure_opts, az_runner)[:unmanaged_resources].find { |i| i[:identifier] == RG_MANUAL }

    assert_equal "microsoft.resources/subscriptions/resourcegroups", item[:resource_type]
    assert_equal "rg-manual", item[:scope]
  end

  test "items are sorted by identifier ignoring case" do
    ids = identifiers(azure_payload(azure_opts, az_runner))
    assert_equal ids.sort_by(&:downcase), ids
  end

  test "raw output summarises the run and lists identifiers" do
    out = azure_payload(azure_opts, az_runner)[:raw_output]

    assert_includes out, "Subscriptions: #{S1}, #{S2}"
    assert_includes out, "Resource Graph rows: 11"
    assert_match(/Managed resource IDs: \d+ from 2 state source/, out)
    assert_includes out, "Unmanaged resources: 4"
    assert_includes out, STMANUAL
  end

  test "directory is sent only when dir is given" do
    assert_equal "infra", azure_payload(azure_opts(dir: "infra"), az_runner)[:directory]
  end

  test "state sources are never echoed into the output" do
    out = azure_payload(azure_opts, az_runner)[:raw_output]
    assert_not_includes out, "lineage"
    assert_not_includes out, "vault.azure.net"
  end

  # --- failure paths: status error and no list ---

  def assert_error(payload, message)
    assert_equal "error", payload[:status]
    assert_equal "azure", payload[:source]
    assert_not payload.key?(:unmanaged_resources)
    assert_match message, payload[:raw_output]
  end

  test "a failing az query gives an error check" do
    runner = FakeRunner.new { on(->(cmd) { cmd.first == "az" }, stderr: "ERROR: Please run 'az login'", exit: 1) }

    assert_error azure_payload(azure_opts, runner), /az graph query failed \(exit 1\).*az login/
  end

  test "a failing second page gives an error check" do
    runner = FakeRunner.new do
      on(->(cmd) { cmd.include?("--skip-token") }, stderr: "throttled", exit: 1)
      stub_az(self)
    end

    assert_error azure_payload(azure_opts, runner), /throttled/
  end

  test "unparseable az output gives an error check" do
    runner = FakeRunner.new { stub_az(self, subscriptions: "not json {") }

    assert_error azure_payload(azure_opts, runner), /did not return valid JSON/
  end

  test "an unexpected az shape gives an error check" do
    runner = FakeRunner.new { stub_az(self, subscriptions: '{"data": "nope"}') }

    assert_error azure_payload(azure_opts, runner), /unexpected JSON shape/
  end

  test "a repeated skip token gives an error check instead of looping" do
    page = JSON.generate("data" => [], "skip_token" => "same")
    runner = FakeRunner.new { stub_az(self, page1: page, page2: page) }

    assert_error azure_payload(azure_opts, runner), /same skip token/
  end

  test "fewer rows than total_records gives an error check" do
    page = JSON.parse(fixture_text("arg_page2.json")).merge("total_records" => 99)
    runner = FakeRunner.new { stub_az(self, page2: JSON.generate(page)) }

    assert_error azure_payload(azure_opts, runner), /returned 11 rows but reported 99 total records/
  end

  test "a missing subscription gives an error check" do
    opts = azure_opts(subscriptions: [ S1, "00000000-0000-0000-0000-000000000099" ])

    assert_error azure_payload(opts, az_runner), /000000000099/
  end

  test "an unreadable state file gives an error check" do
    assert_error azure_payload(azure_opts(state_files: [ "/nonexistent/state.json" ]), az_runner), /cannot read state file/
  end

  test "invalid state JSON gives an error check without quoting the state" do
    path = Rails.root.join("tmp/azure_cli_bad_state.json")
    File.write(path, '{"secret": "hunter2" ')
    payload = azure_payload(azure_opts(state_files: [ path.to_s ]), az_runner)

    assert_error payload, /is not valid JSON/
    assert_not_includes payload[:raw_output], "hunter2"
  ensure
    FileUtils.rm_f(path)
  end

  test "a failing state pull gives an error check" do
    runner = az_runner
    runner.on([ "terraform", "state", "pull" ], stderr: "Backend initialization required", exit: 1)

    assert_error azure_payload(azure_opts(state_dirs: [ "stack" ]), runner), /state pull failed in stack.*Backend initialization/
  end

  test "one unreadable state source fails the whole run" do
    runner = az_runner
    runner.on([ "terraform", "state", "pull" ], stderr: "boom", exit: 1)

    payload = azure_payload(azure_opts(state_dirs: [ "stack" ]), runner)

    assert_error payload, /boom/
    assert_empty graph_calls(runner), "Azure must not be queried when state is incomplete"
  end

  test "zero managed ids gives an error check" do
    empty = Rails.root.join("tmp/azure_cli_empty_state.json")
    File.write(empty, '{"version": 4, "resources": []}')
    payload = azure_payload(azure_opts(state_files: [ empty.to_s ]), az_runner)

    assert_error payload, /no managed resource IDs/
  ensure
    FileUtils.rm_f(empty)
  end

  test "a runner that raises gives an error check" do
    runner = ->(_cmd, **_kw) { raise Errno::ENOENT, "az" }

    assert_error azure_payload(azure_opts, runner), /unexpected Errno::ENOENT/
  end

  test "stderr in error output is truncated" do
    runner = FakeRunner.new { on(->(cmd) { cmd.first == "az" }, stderr: "x" * 10_000, exit: 1) }

    payload = azure_payload(azure_opts, runner)

    assert_operator payload[:raw_output].length, :<, 4200
  end

  # --- limits ---

  test "truncates the list at 5000 and says so" do
    rows = Array.new(5100) do |i|
      { "id" => "/subscriptions/#{S1}/resourceGroups/rg/providers/X.Y/things/t#{format('%05d', i)}", "name" => "t#{i}", "type" => "x.y/things",
        "location" => "westeurope", "resourceGroup" => "rg", "subscriptionId" => S1, "managedBy" => "", "tags" => nil }
    end
    page = JSON.generate("data" => rows, "skip_token" => nil)
    runner = FakeRunner.new { stub_az(self, page1: page) }

    payload = azure_payload(azure_opts, runner)

    assert_equal "ok", payload[:status]
    assert_equal 5000, payload[:unmanaged_resources].size
    assert_includes payload[:raw_output], "100 more were dropped"
    assert_includes payload[:raw_output], "Unmanaged resources: 5100"
  end

  test "lists at most 200 identifiers in the output" do
    rows = Array.new(250) do |i|
      { "id" => "/subscriptions/#{S1}/resourceGroups/rg/providers/X.Y/things/t#{format('%03d', i)}", "name" => "t", "type" => "x.y/things",
        "location" => "w", "resourceGroup" => "rg", "subscriptionId" => S1, "managedBy" => nil, "tags" => nil }
    end
    runner = FakeRunner.new { stub_az(self, page1: JSON.generate("data" => rows)) }

    out = azure_payload(azure_opts, runner)[:raw_output]

    assert_includes out, "... and 50 more"
    assert_equal 200, out.lines.count { |line| line.include?("/things/t") }
  end

  test "tags are dropped when the metadata is large" do
    big = { "id" => "/subscriptions/#{S1}/resourceGroups/rg/providers/X.Y/things/big", "name" => "big", "type" => "x.y/things", "location" => "w",
            "resourceGroup" => "rg", "subscriptionId" => S1, "managedBy" => nil, "tags" => { "k" => "v" * 2000 } }
    runner = FakeRunner.new { stub_az(self, page1: JSON.generate("data" => [ big ])) }

    metadata = azure_payload(azure_opts, runner)[:unmanaged_resources].first[:metadata]

    assert_equal true, metadata[:tags_truncated]
    assert_not metadata.key?(:tags)
    assert_operator metadata.to_json.bytesize, :<, 2048
  end

  test "long identifiers are skipped and counted" do
    long = { "id" => "/subscriptions/#{S1}/resourceGroups/rg/providers/X.Y/things/#{'a' * 1100}", "name" => "n", "type" => "t", "location" => "w",
             "resourceGroup" => "rg", "subscriptionId" => S1, "managedBy" => nil, "tags" => nil }
    runner = FakeRunner.new { stub_az(self, page1: JSON.generate("data" => [ long ])) }

    payload = azure_payload(azure_opts, runner)

    assert_empty payload[:unmanaged_resources]
    assert_includes payload[:raw_output], "Skipped (identifier longer than 1024"
  end

  # --- argument handling ---

  test "requires at least one subscription and one state source" do
    assert_raises(DriftHoundCli::UsageError) { DriftHoundCli::Modes::AzureUnmanaged.new(azure_opts(subscriptions: []), runner: FakeRunner.new) }
    assert_raises(DriftHoundCli::UsageError) { DriftHoundCli::Modes::AzureUnmanaged.new(azure_opts(state_files: []), runner: FakeRunner.new) }
    assert_raises(DriftHoundCli::UsageError) { DriftHoundCli::Modes::AzureUnmanaged.new(azure_opts(state_tool: "pulumi"), runner: FakeRunner.new) }
  end

  test "main parses the azure options and aborts before posting when they are missing" do
    base = %w[--tool=azure --project=p --environment=prod-azure --token=t --api-url=http://x]
    DriftHoundCli::Reporter.expects(:post).never

    _, err = capture_io { assert_equal 1, DriftHoundCli.main(base, runner: FakeRunner.new) }
    assert_match(/Missing --subscription/, err)

    _, err = capture_io { assert_equal 1, DriftHoundCli.main(base + [ "--subscription=#{S1}" ], runner: FakeRunner.new) }
    assert_match(/Missing --state-dir/, err)
  end

  test "main runs the azure mode end to end with repeatable options" do
    runner = FakeRunner.new do
      git(branch: "main")
      on([ "terraform", "state", "pull" ], stdout: fixture_text("tf_state_pull.json"))
    end
    stub_az(runner)
    posted = nil
    DriftHoundCli::Reporter.stubs(:post).with { |opts, payload| posted = [ opts, payload ]; true }.returns(0)

    argv = %W[--tool=azure --project=p --environment=prod-azure --token=t --api-url=http://x --subscription=#{S1} --subscription=#{S2}
              --state-dir=a --state-dir=b --state-file=#{fixture_path('tf_show.json')} --include-managed-by]
    code = nil
    capture_io { code = DriftHoundCli.main(argv, runner: runner) }

    assert_equal 0, code
    assert_equal [ S1, S2 ], posted[0][:subscriptions]
    assert_equal %w[a b], posted[0][:state_dirs]
    assert_equal "azure", posted[1][:source]
    assert_equal "main", posted[0][:branch]
  end
end
