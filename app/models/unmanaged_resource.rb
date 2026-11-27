class UnmanagedResource < ApplicationRecord
  LIMITS = { identifier: 1024, resource_type: 255, name: 255, scope: 255, location: 128, ignore_reason: 600 }.freeze
  METADATA_MAX_BYTES = 2048

  belongs_to :drift_check

  validates :identifier, presence: true
  LIMITS.each do |field, max|
    validates field, length: { maximum: max }, allow_nil: true
  end

  scope :reported, -> { where(ignored: false) }
  scope :ignored_rows, -> { where(ignored: true) }

  def api_json
    {
      identifier: identifier,
      resource_type: resource_type,
      name: name,
      scope: scope,
      location: location,
      metadata: metadata,
      ignored: ignored,
      ignore_reason: ignore_reason
    }
  end
end
