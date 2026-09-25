plan_output_min_role = ENV.fetch("PLAN_OUTPUT_MIN_ROLE", "viewer").strip.downcase

unless %w[viewer editor admin].include?(plan_output_min_role)
  raise "PLAN_OUTPUT_MIN_ROLE must be one of: viewer, editor, admin (got #{ENV['PLAN_OUTPUT_MIN_ROLE'].inspect})"
end

Rails.application.config.plan_output_min_role = plan_output_min_role
