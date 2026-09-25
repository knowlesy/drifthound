trusted_proxy_group_list = ->(value) { value.to_s.split(",").map(&:strip).reject(&:blank?) }

Rails.application.config.trusted_proxy_auth = {
  enabled: ENV.fetch("TRUSTED_PROXY_AUTH_ENABLED", "false") == "true",
  email_header: ENV.fetch("TRUSTED_PROXY_EMAIL_HEADER", "X-Auth-Request-Email"),
  groups_header: ENV.fetch("TRUSTED_PROXY_GROUPS_HEADER", "X-Auth-Request-Groups"),
  role_mappings: {
    admin: trusted_proxy_group_list.call(ENV["TRUSTED_PROXY_ADMIN_GROUPS"]),
    editor: trusted_proxy_group_list.call(ENV["TRUSTED_PROXY_EDITOR_GROUPS"]),
    viewer: trusted_proxy_group_list.call(ENV["TRUSTED_PROXY_VIEWER_GROUPS"])
  },
  default_role: ENV["TRUSTED_PROXY_DEFAULT_ROLE"].presence
}

trusted_proxy_default_role = Rails.application.config.trusted_proxy_auth[:default_role]
if trusted_proxy_default_role && !%w[viewer editor admin].include?(trusted_proxy_default_role)
  raise "TRUSTED_PROXY_DEFAULT_ROLE must be one of: viewer, editor, admin (got #{trusted_proxy_default_role.inspect})"
end
