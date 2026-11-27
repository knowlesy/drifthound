class MetricsController < ActionController::API
  include ApiAuthenticatable

  # Runs before the token check so a disabled endpoint answers 404, not 401
  prepend_before_action :ensure_metrics_enabled!

  def show
    render plain: MetricsExporter.render, content_type: Prometheus::Client::Formats::Text::CONTENT_TYPE
  end

  private

  def ensure_metrics_enabled!
    head :not_found unless Rails.application.config.metrics_enabled
  end
end
