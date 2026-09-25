class TrustedProxyAuthenticator
  class AccessDeniedError < StandardError; end
  class AmbiguousUserError < StandardError; end

  PROVIDER = "trusted_proxy".freeze
  ROLES_BY_PRIORITY = %i[admin editor viewer].freeze

  def initialize(headers, config: Rails.application.config.trusted_proxy_auth)
    @headers = headers
    @config = config
  end

  def authenticate
    return nil unless @config[:enabled]
    return nil if email.blank?

    role = determine_role
    raise AccessDeniedError, "#{email} is not in any group mapped to a DriftHound role" unless role

    find_or_create_user(role)
  end

  private

  def email
    @email ||= @headers[@config[:email_header]].to_s.strip.downcase
  end

  def groups
    @headers[@config[:groups_header]].to_s.split(",").map { |group| group.strip.downcase }.reject(&:blank?)
  end

  def determine_role
    user_groups = groups
    mapped_role = ROLES_BY_PRIORITY.find do |role|
      Array(@config[:role_mappings][role]).map(&:downcase).intersect?(user_groups)
    end

    mapped_role || @config[:default_role]&.to_sym
  end

  def find_or_create_user(role)
    user = find_user
    return create_user(role) unless user

    user.update!(role: role) unless user.role == role.to_s
    user
  end

  def find_user
    matches = User.where("LOWER(TRIM(email)) = ?", email).order(:id).to_a
    return matches.first if matches.size <= 1

    raise AmbiguousUserError, "#{email} matches #{matches.size} users (ids #{matches.map(&:id).join(', ')}) that differ only in case or whitespace"
  end

  def create_user(role)
    User.create!(email: email, provider: PROVIDER, uid: email, role: role)
  rescue ActiveRecord::RecordNotUnique
    find_user || raise
  end
end
