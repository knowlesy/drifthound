module Api
  module V1
    class UnmanagedIgnoreRulesController < BaseController
      RULE_PARAMS = %i[pattern field match_type source note].freeze

      before_action :set_environment

      # GET /api/v1/projects/:project_key/environments/:environment_key/ignore_rules
      def index
        # User rules hold full resource IDs (one-click Ignore), so they follow the plan output rule
        json = { builtin_rules: builtin_rules_json }
        if current_api_token.can_read_plan_output?
          json[:ignore_rules] = @environment.unmanaged_ignore_rules.order(:id).map(&:api_json)
        else
          json[:ignore_rules_restricted] = true
        end
        render json: json
      end

      # POST /api/v1/projects/:project_key/environments/:environment_key/ignore_rules
      # Body params: pattern (required), field, match_type, source, note
      def create
        attributes = rule_attributes
        return if performed?

        rule = @environment.unmanaged_ignore_rules.build(attributes)
        rule.save!
        render json: rule.api_json, status: :created
      end

      # DELETE /api/v1/projects/:project_key/environments/:environment_key/ignore_rules/:id
      def destroy
        @environment.unmanaged_ignore_rules.find(params[:id]).destroy!
        head :no_content
      end

      private

      def set_environment
        project = Project.find_by!(key: params[:project_key])
        @environment = project.environments.find_by!(key: params[:environment_key])
      end

      # Only plain strings are accepted: an array or object would otherwise be
      # dropped by strong parameters and silently widen the rule (for example a
      # rule for one source becoming a rule for all sources).
      def rule_attributes
        RULE_PARAMS.each_with_object({}) do |name, attributes|
          next unless params.key?(name)

          value = params[name]
          next if value.nil?

          unless value.is_a?(String)
            render json: { error: "#{name} must be a string" }, status: :unprocessable_entity
            return nil
          end
          attributes[name] = value
        end
      end

      def builtin_rules_json
        BuiltinIgnoreRules::REGISTRY.transform_values do |rules|
          rules.map { |r| r.to_h.slice(:key, :field, :match_type, :pattern, :note) }
        end
      end
    end
  end
end
