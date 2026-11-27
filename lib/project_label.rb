# Reads the configured project label on every call so tests can override it.
module ProjectLabel
  def self.text(plural: false, lowercase: false)
    config = Rails.application.config.project_label
    label = plural ? config[:plural] : config[:singular]
    # Only lower-case Capitalised words so acronyms ("AWS Account" -> "AWS account") survive.
    label = label.gsub(/\b[[:upper:]][[:lower:]]+\b/, &:downcase) if lowercase
    label
  end
end
