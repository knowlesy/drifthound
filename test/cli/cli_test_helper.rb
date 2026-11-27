require "test_helper"

# The CLI is a single self-contained script, so it is loaded rather than required
load Rails.root.join("bin/drifthound-cli").to_s unless defined?(DriftHoundCli)

module AzureCliFixtures
  FIXTURE_DIR = Rails.root.join("test/fixtures/files/azure")
  S1 = "00000000-0000-0000-0000-000000000001".freeze
  S2 = "00000000-0000-0000-0000-000000000002".freeze

  def fixture_path(name)
    FIXTURE_DIR.join(name).to_s
  end

  def fixture_text(name)
    File.read(fixture_path(name))
  end

  # Answers `az graph query` from the fixtures: the subscriptions query, then
  # page 1 and (after a --skip-token) page 2 of the resource query.
  def stub_az(runner, page1: fixture_text("arg_page1.json"), page2: fixture_text("arg_page2.json"), subscriptions: fixture_text("arg_subscriptions.json"))
    runner.on(->(cmd) { cmd.first(3) == %w[az graph query] }) do |cmd, _|
      if cmd.include?("--skip-token")
        [ page2, "", 0 ]
      elsif cmd[cmd.index("-q") + 1] == DriftHoundCli::Modes::AzureUnmanaged::SUBSCRIPTIONS_QUERY
        [ subscriptions, "", 0 ]
      else
        [ page1, "", 0 ]
      end
    end
  end

  def azure_opts(**extra)
    { tool: "azure", project: "p", environment: "prod-azure", token: "tok", api_url: "http://dh.test",
      subscriptions: [ S1, S2 ], state_files: [ fixture_path("tf_show.json"), fixture_path("tf_state_pull.json") ] }.merge(extra)
  end

  def azure_payload(opts, runner)
    payload = nil
    capture_io { payload = DriftHoundCli::Modes::AzureUnmanaged.new(opts, runner: runner).build_payload }
    payload
  end

  def identifiers(payload)
    payload[:unmanaged_resources].map { |item| item[:identifier] }
  end
end

module CliTestHelper
  FakeStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  # Records every call and answers from a list of [matcher, response] pairs.
  # A matcher is a Proc over the command array; a response is [stdout, stderr, exit] or a Proc.
  class FakeRunner
    include AzureCliFixtures

    attr_reader :calls

    def initialize(&block)
      @calls = []
      @routes = []
      instance_eval(&block) if block
    end

    def on(matcher = nil, stdout: "", stderr: "", exit: 0, &handler)
      prefix = Array(matcher)
      test = matcher.respond_to?(:call) ? matcher : ->(cmd) { cmd.first(prefix.size) == prefix }
      @routes << [ test, handler || ->(_cmd, _chdir) { [ stdout, stderr, exit ] } ]
    end

    def call(cmd, chdir: nil)
      @calls << { cmd: cmd, chdir: chdir }
      _matcher, handler = @routes.find { |matcher, _| matcher.call(cmd) }
      raise "unexpected command: #{cmd.inspect}" unless handler

      out, err, code = handler.call(cmd, chdir)
      [ out, err, FakeStatus.new(code) ]
    end

    def commands
      @calls.map { |c| c[:cmd] }
    end

    # Answers the git remote and branch lookups
    def git(remote: "git@github.com:org/repo.git", branch: "main")
      on([ "git", "-C" ]) { |cmd, _| cmd.include?("remote") ? [ "#{remote}\n", "", 0 ] : [ "#{branch}\n", "", 0 ] }
    end
  end
end
