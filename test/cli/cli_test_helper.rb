require "test_helper"

# The CLI is a single self-contained script, so it is loaded rather than required
load Rails.root.join("bin/drifthound-cli").to_s unless defined?(DriftHoundCli)

module CliTestHelper
  FakeStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  # Records every call and answers from a list of [matcher, response] pairs.
  # A matcher is a Proc over the command array; a response is [stdout, stderr, exit] or a Proc.
  class FakeRunner
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
