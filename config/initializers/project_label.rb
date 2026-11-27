# Display-only label for what DriftHound calls a "project" (e.g. "Layer").
# The API, CLI, URLs and database keep using "project".
project_label = ENV["PROJECT_LABEL"].to_s.strip.presence || "Project"
project_label_plural = ENV["PROJECT_LABEL_PLURAL"].to_s.strip.presence || project_label.pluralize

Rails.application.config.project_label = {
  singular: project_label,
  plural: project_label_plural
}
