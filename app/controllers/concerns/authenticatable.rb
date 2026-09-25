module Authenticatable
  extend ActiveSupport::Concern

  included do
    helper_method :current_user, :logged_in?, :public_mode?
    before_action :authenticate_from_trusted_proxy
  end

  def current_user
    @current_user ||= (User.find_by(id: session[:user_id]) if session[:user_id])
  end

  def logged_in?
    current_user.present?
  end

  def public_mode?
    Rails.application.config.public_mode
  end

  def require_login
    unless logged_in?
      flash[:alert] = "You must be logged in to perform this action"
      redirect_to login_path
    end
  end

  # Requires login only when not in public mode
  # Use this for read-only actions that should be public when public_mode is enabled
  def require_login_unless_public
    require_login unless public_mode?
  end

  private

  def authenticate_from_trusted_proxy
    user = TrustedProxyAuthenticator.new(request.headers).authenticate
    @current_user = user if user
  rescue TrustedProxyAuthenticator::AccessDeniedError => e
    Rails.logger.warn "Trusted proxy access denied: #{e.message}"
    render plain: "Access denied. Your account is not in any group mapped to a DriftHound role.", status: :forbidden
  rescue TrustedProxyAuthenticator::AmbiguousUserError => e
    Rails.logger.error "Trusted proxy login refused: #{e.message}"
    render plain: "Access denied. More than one DriftHound account matches your email address; ask an administrator to remove the duplicate.", status: :forbidden
  end
end
