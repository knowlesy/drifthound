# Shared matching logic for built-in and user-defined ignore rules.
# Including classes must respond to #field, #match_type and #pattern.
#
# Matching is always case-insensitive (Azure IDs are). Glob patterns use
# File.fnmatch? without FNM_PATHNAME, so "*" also matches "/". Braces are
# literal. There is no regex support, so no ReDoS risk.
module UnmanagedIgnoreMatching
  extend ActiveSupport::Concern

  GLOB_FLAGS = File::FNM_CASEFOLD | File::FNM_DOTMATCH

  # attrs is a Hash with String keys from UnmanagedIgnoreRule::FIELDS
  def matches?(attrs)
    value = attrs[field].to_s
    return false if value.empty?

    match_type == "exact" ? value.casecmp?(pattern) : File.fnmatch?(pattern, value, GLOB_FLAGS)
  end

  def description
    "#{field} #{match_type == 'exact' ? '=' : 'matches'} #{pattern}"
  end
end
