class UnmanagedIgnoreRule < ApplicationRecord
  include UnmanagedIgnoreMatching

  FIELDS = %w[identifier resource_type name scope location].freeze
  MATCH_TYPES = %w[exact glob].freeze
  MAX_PER_ENVIRONMENT = 200
  PATTERN_MAX_LENGTH = 1024

  belongs_to :environment
  belongs_to :created_by, class_name: "User", optional: true

  validates :field, inclusion: { in: FIELDS }
  validates :match_type, inclusion: { in: MATCH_TYPES }
  validates :pattern, presence: true,
                      length: { maximum: PATTERN_MAX_LENGTH },
                      format: { with: /\A[[:print:]]+\z/, message: "must not contain control characters or newlines" }
  validates :source, inclusion: { in: DriftCheck.sources.keys }, allow_nil: true
  validates :note, length: { maximum: 255 }
  validates :pattern, uniqueness: { scope: [ :environment_id, :field, :match_type, :source ], case_sensitive: false },
                      if: -> { errors[:pattern].empty? }
  validate :environment_rule_limit, on: :create

  # Built-in rules first, then the environment's own rules in creation order
  def self.effective_rules(environment, source)
    BuiltinIgnoreRules.for(source) +
      environment.unmanaged_ignore_rules.order(:id).to_a.select { |r| r.source.nil? || r.source == source.to_s }
  end

  def ignore_reason
    "Rule ##{id}: #{description}"
  end

  def api_json
    { id: id, field: field, match_type: match_type, pattern: pattern, source: source, note: note, created_at: created_at }
  end

  private

  def environment_rule_limit
    return unless environment

    if environment.unmanaged_ignore_rules.count >= MAX_PER_ENVIRONMENT
      errors.add(:base, "An environment can have at most #{MAX_PER_ENVIRONMENT} ignore rules")
    end
  end
end
