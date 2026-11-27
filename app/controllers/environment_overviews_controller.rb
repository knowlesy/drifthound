class EnvironmentOverviewsController < ApplicationController
  before_action :require_login_unless_public
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def show
    @environments = Environment.where(key: params[:key]).joins(:project).preload(:project).order("projects.name", :id).to_a
    raise ActiveRecord::RecordNotFound if @environments.empty?

    @key = params[:key]
    @latest_checks = Environment.latest_checks_for(@environments)
  end

  private

  def not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
