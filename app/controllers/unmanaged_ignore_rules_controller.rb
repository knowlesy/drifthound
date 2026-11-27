class UnmanagedIgnoreRulesController < ApplicationController
  before_action :require_login
  before_action :set_project_and_environment
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def create
    rule = @environment.unmanaged_ignore_rules.build(rule_params.merge(created_by: current_user))
    authorize rule

    if rule.save
      redirect_to environment_path, notice: "Ignore rule added. It applies from the next check."
    else
      redirect_to environment_path, alert: "Could not add the ignore rule: #{rule.errors.full_messages.to_sentence}"
    end
  end

  def destroy
    rule = @environment.unmanaged_ignore_rules.find(params[:id])
    authorize rule
    rule.destroy!
    redirect_to environment_path, notice: "Ignore rule removed. It no longer applies from the next check."
  end

  private

  def set_project_and_environment
    @project = Project.find_by!(key: params[:project_key])
    @environment = @project.environments.find_by!(key: params[:key])
  end

  def environment_path
    project_environment_path(@project.key, @environment.key)
  end

  def rule_params
    params.expect(unmanaged_ignore_rule: [ :pattern, :field, :match_type, :source, :note ]).tap do |permitted|
      permitted[:source] = nil if permitted[:source].blank?
      permitted[:note] = nil if permitted[:note].blank?
    end
  end

  def not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
