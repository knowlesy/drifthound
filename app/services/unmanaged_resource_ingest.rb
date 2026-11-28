# Validates the unmanaged_resources array of a check submission, applies the
# effective ignore rules and returns rows ready for UnmanagedResource.insert_all!.
class UnmanagedResourceIngest
  class InvalidPayload < ArgumentError; end

  # unmanaged_count counts the rows that were NOT ignored. Both counts are nil
  # when the check sent no inventory at all.
  Result = Data.define(:rows, :unmanaged_count, :ignored_count)

  STRING_FIELDS = %i[resource_type name scope location].freeze

  def initialize(environment:, source:, items:)
    @environment = environment
    @source = source.to_s
    @items = items
  end

  def call
    return Result.new(rows: [], unmanaged_count: nil, ignored_count: nil) if @items.nil?

    validate_collection!
    rules = UnmanagedIgnoreRule.effective_rules(@environment, @source)

    seen = Set.new
    rows = []
    @items.each_with_index do |item, index|
      row = build_row(item, index)
      next unless seen.add?(row[:identifier].downcase)

      rule = rules.find { |r| r.matches?(match_attributes(row)) }
      row[:ignored] = !rule.nil?
      row[:ignore_reason] = rule&.ignore_reason&.slice(0, UnmanagedResource::LIMITS[:ignore_reason])
      rows << row
    end

    ignored = rows.count { |r| r[:ignored] }
    Result.new(rows: rows, unmanaged_count: rows.size - ignored, ignored_count: ignored)
  end

  private

  def validate_collection!
    unless @items.is_a?(Array) && @items.all?(Hash)
      raise InvalidPayload, "unmanaged_resources must be an array of objects"
    end
    if @items.size > DriftCheck::MAX_UNMANAGED_RESOURCES
      raise InvalidPayload, "unmanaged_resources has more than #{DriftCheck::MAX_UNMANAGED_RESOURCES} items"
    end
  end

  def build_row(item, index)
    identifier = item["identifier"]
    unless identifier.is_a?(String) && identifier.strip.present?
      raise InvalidPayload, "unmanaged_resources[#{index}].identifier must be a non-blank string"
    end

    row = { identifier: checked_string(identifier, index, :identifier).strip }
    STRING_FIELDS.each do |field|
      value = item[field.to_s]
      unless value.nil? || value.is_a?(String)
        raise InvalidPayload, "unmanaged_resources[#{index}].#{field} must be a string"
      end
      row[field] = value.nil? ? nil : checked_string(value, index, field).strip.presence
    end
    row[:metadata] = checked_metadata(item["metadata"], index)
    row
  end

  # Checks the raw value: String#strip would silently drop a trailing NUL
  def checked_string(value, index, field)
    if value.include?("\u0000")
      raise InvalidPayload, "unmanaged_resources[#{index}].#{field} must not contain NUL characters"
    end
    max = UnmanagedResource::LIMITS.fetch(field)
    if value.length > max
      raise InvalidPayload, "unmanaged_resources[#{index}].#{field} is too long (maximum is #{max} characters)"
    end
    value
  end

  def checked_metadata(value, index)
    return {} if value.nil?

    raise InvalidPayload, "unmanaged_resources[#{index}].metadata must be an object" unless value.is_a?(Hash)
    if contains_nul?(value)
      raise InvalidPayload, "unmanaged_resources[#{index}].metadata must not contain NUL characters"
    end
    # JSON.generate, not ActiveSupport's to_json: that one escapes & < > as six bytes
    if JSON.generate(value).bytesize > UnmanagedResource::METADATA_MAX_BYTES
      raise InvalidPayload, "unmanaged_resources[#{index}].metadata is too large (maximum is #{UnmanagedResource::METADATA_MAX_BYTES} bytes)"
    end
    value
  end

  # JSON escapes NUL as the six characters \u0000, so look at the raw strings
  def contains_nul?(value)
    case value
    when String then value.include?("\u0000")
    when Hash then value.any? { |k, v| contains_nul?(k) || contains_nul?(v) }
    when Array then value.any? { |v| contains_nul?(v) }
    else false
    end
  end

  def match_attributes(row)
    UnmanagedIgnoreRule::FIELDS.index_with { |field| row[field.to_sym] }
  end
end
