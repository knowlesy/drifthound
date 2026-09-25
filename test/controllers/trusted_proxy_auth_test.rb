require "test_helper"

class TrustedProxyAuthTest < ActionDispatch::IntegrationTest
  setup do
    @original_config = Rails.application.config.trusted_proxy_auth
    @original_public_mode = Rails.application.config.public_mode
    Rails.application.config.public_mode = false
    configure_trusted_proxy(enabled: false)
  end

  teardown do
    Rails.application.config.trusted_proxy_auth = @original_config
    Rails.application.config.public_mode = @original_public_mode
  end

  test "ignores proxy headers when disabled" do
    assert_no_difference "User.count" do
      get root_path, headers: proxy_headers("newcomer@example.com", "drifthound-admins")
    end

    assert_redirected_to login_path
  end

  test "ignores proxy headers for an existing user when disabled" do
    get root_path, headers: proxy_headers(users(:admin).email, "drifthound-admins")

    assert_redirected_to login_path
  end

  test "logs in and provisions a new user when enabled" do
    configure_trusted_proxy

    assert_difference "User.count", 1 do
      get root_path, headers: proxy_headers("Newcomer@Example.com", "drifthound-editors")
    end

    assert_response :success
    user = User.find_by(email: "newcomer@example.com")
    assert user.editor?
    assert_equal "trusted_proxy", user.provider
    assert_equal "newcomer@example.com", user.uid
  end

  test "logs in an existing user by email without creating a new one" do
    configure_trusted_proxy

    assert_no_difference "User.count" do
      get root_path, headers: proxy_headers(users(:viewer).email, "drifthound-viewers")
    end

    assert_response :success
  end

  test "stores a trimmed, lowercased email for a newly provisioned user" do
    configure_trusted_proxy

    get root_path, headers: proxy_headers("  Mixed.Case@Example.COM ", "drifthound-viewers")

    assert_response :success
    user = User.order(:id).last
    assert_equal "mixed.case@example.com", user.email
    assert_equal "mixed.case@example.com", user.uid
  end

  test "matches an existing user whose stored email differs only in case" do
    configure_trusted_proxy
    existing = User.create!(email: "Legacy.User@Example.com", password: "testpass1", role: :viewer)

    assert_no_difference "User.count" do
      get root_path, headers: proxy_headers("legacy.user@example.com", "drifthound-editors")
    end

    assert_response :success
    assert existing.reload.editor?
  end

  test "refuses and logs an error when several users match the email case-insensitively" do
    configure_trusted_proxy
    first = User.create!(email: "twin@example.com", password: "testpass1", role: :viewer)
    second = User.create!(email: "Twin@Example.com", password: "testpass1", role: :viewer)
    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)

    begin
      assert_no_difference "User.count" do
        get root_path, headers: proxy_headers("twin@example.com", "drifthound-admins")
      end
    ensure
      Rails.logger = original_logger
    end

    assert_response :forbidden
    assert_match "More than one DriftHound account", response.body
    assert_match "twin@example.com matches 2 users", log.string
    assert first.reload.viewer?
    assert second.reload.viewer?
  end

  test "maps groups to the highest matching role" do
    configure_trusted_proxy

    get root_path, headers: proxy_headers("multi@example.com", "drifthound-viewers, drifthound-admins,drifthound-editors")

    assert_response :success
    assert User.find_by(email: "multi@example.com").admin?
  end

  test "matches groups case-insensitively" do
    configure_trusted_proxy

    get root_path, headers: proxy_headers("casey@example.com", "DriftHound-Editors")

    assert_response :success
    assert User.find_by(email: "casey@example.com").editor?
  end

  test "updates the role of an existing user from their groups" do
    configure_trusted_proxy
    viewer = users(:viewer)

    get root_path, headers: proxy_headers(viewer.email, "drifthound-admins")

    assert_response :success
    assert viewer.reload.admin?
  end

  test "reads custom header names" do
    configure_trusted_proxy(email_header: "X-Forwarded-Email", groups_header: "X-Forwarded-Groups")

    get root_path, headers: { "X-Forwarded-Email" => "custom@example.com", "X-Forwarded-Groups" => "drifthound-admins" }

    assert_response :success
    assert User.find_by(email: "custom@example.com").admin?
  end

  test "refuses a user in no mapped group when no default role is set" do
    configure_trusted_proxy

    assert_no_difference "User.count" do
      get root_path, headers: proxy_headers("outsider@example.com", "some-other-group")
    end

    assert_response :forbidden
    assert_match "Access denied", response.body
  end

  test "refuses a user with no groups header when no default role is set" do
    configure_trusted_proxy

    get root_path, headers: { "X-Auth-Request-Email" => "outsider@example.com" }

    assert_response :forbidden
  end

  test "grants the default role to a user in no mapped group when configured" do
    configure_trusted_proxy(default_role: "viewer")

    get root_path, headers: proxy_headers("outsider@example.com", "some-other-group")

    assert_response :success
    assert User.find_by(email: "outsider@example.com").viewer?
  end

  test "falls back to normal login when the email header is missing" do
    configure_trusted_proxy

    get root_path
    assert_redirected_to login_path

    post login_path, params: { email: users(:admin).email, password: "testpass1" }
    get root_path
    assert_response :success
  end

  test "proxy identity takes precedence over an existing session" do
    configure_trusted_proxy
    post login_path, params: { email: users(:admin).email, password: "testpass1" }

    get users_path, headers: proxy_headers(users(:viewer).email, "drifthound-viewers")

    assert_redirected_to root_path
    assert_equal "You are not authorized to perform this action.", flash[:alert]
  end

  test "pundit authorizes proxy users by their mapped role" do
    configure_trusted_proxy

    get users_path, headers: proxy_headers("boss@example.com", "drifthound-admins")
    assert_response :success

    get users_path, headers: proxy_headers("reader@example.com", "drifthound-viewers")
    assert_redirected_to root_path
  end

  test "api token authentication is unaffected by proxy headers" do
    configure_trusted_proxy
    api_token = ApiToken.create!(name: "proxy-test-token")

    post api_v1_environment_checks_path("proxy-project", "production"),
      params: { status: "ok" },
      headers: proxy_headers("outsider@example.com", "some-other-group").merge("Authorization" => "Bearer #{api_token.token}"),
      as: :json
    assert_response :created

    post api_v1_environment_checks_path("proxy-project", "production"),
      params: { status: "ok" },
      headers: proxy_headers(users(:admin).email, "drifthound-admins"),
      as: :json
    assert_response :unauthorized
  end

  private

  def configure_trusted_proxy(**overrides)
    Rails.application.config.trusted_proxy_auth = {
      enabled: true,
      email_header: "X-Auth-Request-Email",
      groups_header: "X-Auth-Request-Groups",
      role_mappings: {
        admin: [ "drifthound-admins" ],
        editor: [ "drifthound-editors" ],
        viewer: [ "drifthound-viewers" ]
      },
      default_role: nil
    }.merge(overrides)
  end

  def proxy_headers(email, groups)
    { "X-Auth-Request-Email" => email, "X-Auth-Request-Groups" => groups }
  end
end
