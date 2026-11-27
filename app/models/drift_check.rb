class DriftCheck < ApplicationRecord
  belongs_to :environment, touch: true

  enum :status, {
    unknown: 0,
    ok: 1,
    drift: 2,
    error: 3
  }

  enum :source, {
    terraform: "terraform",
    azure: "azure",
    argocd: "argocd"
  }, prefix: true, validate: true, default: "terraform"

  has_many :unmanaged_resources, dependent: :delete_all

  MAX_UNMANAGED_RESOURCES = 5000
  BRANCH_MAX_LENGTH = 255
  INVALID_BRANCH_PATTERN = %r{[\x00-\x20\x7f~^:?*\[\\]|\.\.|@\{|//|/\.|\.lock(?:/|\z)|\A[-/.]|[/.]\z}

  normalizes :branch, with: ->(branch) { branch.strip.presence }

  validates :status, presence: true
  validates :branch, length: { maximum: BRANCH_MAX_LENGTH }, allow_nil: true
  validates :branch, format: { without: INVALID_BRANCH_PATTERN, message: "is not a valid git branch name" }, allow_nil: true

  def self.valid_branch_name?(name)
    !INVALID_BRANCH_PATTERN.match?(name)
  end

  before_create :assign_execution_number
  after_create :update_environment_status
  after_create :enforce_retention_limit
  def assign_execution_number
    last_number = environment.drift_checks.maximum(:execution_number) || 0
    self.execution_number = last_number + 1
  end

  # Delegate project access for convenience
  delegate :project, to: :environment

  # True when the check sent an unmanaged-resource inventory (even an empty one)
  def reports_inventory?
    !unmanaged_count.nil?
  end

  # Decides the final status before the record is created. "error" always wins,
  # any non-ignored unmanaged resource makes the check drift, otherwise the
  # reported status is kept. Returns nil when no status can be determined.
  def self.resolve_status(reported:, source:, unmanaged_count:)
    reported = reported.presence || (source.to_s == "terraform" ? nil : "ok")
    return nil if reported.nil?

    reported = reported.to_s
    raise ArgumentError, "status is not a valid status" unless statuses.key?(reported)

    return "error" if reported == "error"
    return "drift" if unmanaged_count.to_i > 0

    reported
  end

  def summary_parts
    parts = []
    parts << "#{add_count} to add" if add_count && add_count > 0
    parts << "#{change_count} to change" if change_count && change_count > 0
    parts << "#{destroy_count} to destroy" if destroy_count && destroy_count > 0
    parts << "#{unmanaged_count} unmanaged" if unmanaged_count && unmanaged_count > 0
    parts
  end

  def change_summary
    return nil unless drift?
    return "No changes specified" if add_count.nil? && change_count.nil? && destroy_count.nil? && unmanaged_count.nil?

    parts = summary_parts
    parts.any? ? parts.join(", ") : "No changes"
  end

  private

  def update_environment_status
    environment.update!(status: status, last_checked_at: created_at)
  end

  def enforce_retention_limit
    retention_days = Rails.application.config.drift_check_retention_days

    # Skip retention if disabled (0 days)
    return if retention_days.zero?

    environment.delete_checks_before(retention_days.days.ago)
  end
end
