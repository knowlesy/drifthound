require_relative "cli_test_helper"

class DriftHoundCliTest < ActiveSupport::TestCase
  include CliTestHelper

  OPTS = { tool: "terraform", project: "p", environment: "prod", token: "tok", api_url: "http://dh.test" }.freeze

  def plan_payload(exit_code:, stdout: "", stderr: "", tool: "terraform", dir: "/work")
    runner = FakeRunner.new { on(exit: exit_code, stdout: stdout, stderr: stderr) }
    payload = nil
    capture_io { payload = DriftHoundCli::Modes::Plan.new(OPTS.merge(tool: tool, dir: dir), runner: runner).build_payload }
    [ payload, runner ]
  end

  test "plan with exit code 0 is ok" do
    payload, runner = plan_payload(exit_code: 0, stdout: "No changes. Your infrastructure matches the configuration.")

    assert_equal "ok", payload[:status]
    assert_equal "terraform", payload[:source]
    assert_equal [ 0, 0, 0 ], payload.values_at(:add_count, :change_count, :destroy_count)
    assert_equal "/work", payload[:directory]
    assert_equal [ %w[terraform plan -no-color -detailed-exitcode -lock=false] ], runner.commands
    assert_equal "/work", runner.calls.first[:chdir]
  end

  test "plan with exit code 2 is drift and parses the counts" do
    payload, _ = plan_payload(exit_code: 2, stdout: "Plan: 3 to add, 2 to change, 1 to destroy.")

    assert_equal "drift", payload[:status]
    assert_equal [ 3, 2, 1 ], payload.values_at(:add_count, :change_count, :destroy_count)
    assert_includes payload[:raw_output], "Plan: 3 to add"
    assert_kind_of Float, payload[:duration]
  end

  test "plan with exit code 1 is an error and keeps stderr in the output" do
    payload, _ = plan_payload(exit_code: 1, stderr: "Error: no config files")

    assert_equal "error", payload[:status]
    assert_includes payload[:raw_output], "Error: no config files"
  end

  test "plan asks the runner to merge stderr into stdout" do
    _, runner = plan_payload(exit_code: 0)
    assert_equal true, runner.calls.first[:merge_stderr]
  end

  test "the default runner keeps stdout and stderr interleaved when merging" do
    cmd = [ "sh", "-c", "echo out1; echo err1 >&2; echo out2; echo err2 >&2" ]

    out, err, status = DriftHoundCli::DEFAULT_RUNNER.call(cmd, merge_stderr: true)
    assert_equal "out1\nerr1\nout2\nerr2\n", out
    assert_equal "", err
    assert status.success?

    out, err, = DriftHoundCli::DEFAULT_RUNNER.call(cmd)
    assert_equal "out1\nout2\n", out
    assert_equal "err1\nerr2\n", err
  end

  test "terragrunt runs terragrunt" do
    _, runner = plan_payload(exit_code: 0, tool: "terragrunt")
    assert_equal "terragrunt", runner.commands.first.first
  end

  test "a runner that raises becomes an error check" do
    runner = ->(_cmd, **_kw) { raise Errno::ENOENT, "terraform" }
    payload = nil
    capture_io { payload = DriftHoundCli::Modes::Plan.new(OPTS.merge(dir: "/work"), runner: runner).build_payload }

    assert_equal "error", payload[:status]
    assert_match(/Error: No such file/, payload[:raw_output])
  end

  test "invalid bytes in command output are replaced" do
    payload, _ = plan_payload(exit_code: 0, stdout: "ok \xFF done".b)
    assert payload[:raw_output].valid_encoding?
    assert_includes payload[:raw_output], "ok ? done"
  end

  test "Unmanaged.truncate keeps at most max items" do
    items = (1..5).to_a
    assert_equal [ items, 0 ], DriftHoundCli::Unmanaged.truncate(items, max: 5)
    assert_equal [ [ 1, 2, 3 ], 2 ], DriftHoundCli::Unmanaged.truncate(items, max: 3)
  end

  test "git helpers sanitize and convert urls through the runner" do
    runner = FakeRunner.new { git(remote: "git@github.com:org/repo.git", branch: "feature/x") }

    assert_equal "https://github.com/org/repo", DriftHoundCli::Git.detect_repository("/work", runner)
    assert_equal "feature/x", DriftHoundCli::Git.detect_branch("/work", runner)
    assert_equal [ "git", "-C", "/work", "remote", "get-url", "origin" ], runner.commands.first
    assert_equal "https://github.com/org/repo", DriftHoundCli::Git.sanitize_repository_url("https://user:secret@github.com/org/repo")
  end

  test "git helpers handle ssh urls, detached HEAD and failures" do
    ssh = FakeRunner.new { on(stdout: "ssh://git@gitlab.com/org/repo.git\n") }
    assert_equal "https://gitlab.com/org/repo", DriftHoundCli::Git.detect_repository("/w", ssh)

    detached = FakeRunner.new { on(stdout: "HEAD\n") }
    assert_nil DriftHoundCli::Git.detect_branch("/w", detached)

    failing = FakeRunner.new { on(exit: 128) }
    assert_nil DriftHoundCli::Git.detect_repository("/w", failing)

    missing = ->(_cmd, **_kw) { raise Errno::ENOENT, "git" }
    assert_nil DriftHoundCli::Git.detect_repository("/w", missing)
  end

  test "autodetect keeps explicit values and sanitizes the repository" do
    opts = { repository: "https://u:t@github.com/o/r", branch: "release" }
    runner = FakeRunner.new
    capture_io { DriftHoundCli::Git.autodetect!(opts, "/w", runner) }

    assert_equal "https://github.com/o/r", opts[:repository]
    assert_equal "release", opts[:branch]
    assert_empty runner.calls
  end

  test "Reporter posts JSON to the check URL with a bearer token" do
    response = Struct.new(:code, :body).new("201", "{}")
    captured = {}
    Net::HTTP.stubs(:start).with { |host, port, **kw| captured.merge!(host: host, port: port, ssl: kw[:use_ssl]); true }.yields(
      Object.new.tap do |http|
        http.define_singleton_method(:request) do |req|
          captured[:req] = req
          response
        end
      end
    ).returns(response)

    code = nil
    capture_io do
      code = DriftHoundCli::Reporter.post(
        OPTS.merge(api_url: "https://dh.example.com", repository: "https://github.com/o/r", branch: "main", environment_name: "Prod", slack_channel: "#drift"),
        { status: "ok", source: "terraform" }
      )
    end

    assert_equal 0, code
    assert_equal [ "dh.example.com", 443, true ], captured.values_at(:host, :port, :ssl)
    req = captured[:req]
    assert_equal "/api/v1/projects/p/environments/prod/checks", req.path
    assert_equal "Bearer tok", req["Authorization"]
    assert_equal "application/json", req["Content-Type"]
    body = JSON.parse(req.body)
    assert_equal "ok", body["status"]
    assert_equal "https://github.com/o/r", body["repository"]
    assert_equal "main", body["branch"]
    assert_equal "Prod", body["environment_name"]
    assert_equal({ "channel_type" => "slack", "enabled" => true, "config" => { "channel" => "#drift" } }, body["notification_channel"])
  end

  test "Reporter prints the status the server recorded" do
    Net::HTTP.stubs(:start).returns(Struct.new(:code, :body).new("201", { status: "drift", unmanaged_count: 2 }.to_json))
    out, _ = capture_io { assert_equal 0, DriftHoundCli::Reporter.post(OPTS, { status: "ok", source: "azure" }) }
    assert_match(/^Recorded status: drift$/, out)

    Net::HTTP.stubs(:start).returns(Struct.new(:code, :body).new("201", "not json"))
    out, _ = capture_io { assert_equal 0, DriftHoundCli::Reporter.post(OPTS, { status: "ok" }) }
    assert_no_match(/Recorded status/, out)

    Net::HTTP.stubs(:start).returns(Struct.new(:code, :body).new("422", { status: "error" }.to_json))
    out, _ = capture_io { assert_equal 1, DriftHoundCli::Reporter.post(OPTS, { status: "ok" }) }
    assert_no_match(/Recorded status/, out)
  end

  test "Reporter returns 1 for HTTP errors and for connection failures" do
    Net::HTTP.stubs(:start).returns(Struct.new(:code, :body).new("422", "{}"))
    capture_io { assert_equal 1, DriftHoundCli::Reporter.post(OPTS, { status: "ok" }) }

    Net::HTTP.stubs(:start).raises(Errno::ECONNREFUSED)
    out, _ = capture_io { assert_equal 1, DriftHoundCli::Reporter.post(OPTS, { status: "ok" }) }
    assert_match(/Error sending API request/, out)
  end

  test "main runs the plan and reports it" do
    runner = FakeRunner.new do
      git
      on([ "terraform" ], stdout: "Plan: 1 to add, 0 to change, 0 to destroy.", exit: 2)
    end
    posted = nil
    DriftHoundCli::Reporter.stubs(:post).with { |opts, payload| posted = [ opts, payload ]; true }.returns(0)

    code = nil
    capture_io do
      code = DriftHoundCli.main(%w[--tool=terraform --project=p --environment=prod --token=tok --api-url=http://x --dir=/work], runner: runner)
    end

    assert_equal 0, code
    assert_equal "drift", posted[1][:status]
    assert_equal "https://github.com/org/repo", posted[0][:repository]
    assert_equal "main", posted[0][:branch]
  end

  test "main rejects missing options and unknown tools" do
    [ %w[--project=p], %w[--tool=nope --project=p --environment=e --token=t --api-url=u], %w[--bogus] ].each do |argv|
      _, err = capture_io { assert_equal 1, DriftHoundCli.main(argv, runner: FakeRunner.new) }
      assert err.present?, argv.inspect
    end
  end
end
