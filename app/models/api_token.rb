class ApiToken < ApplicationRecord
  has_secure_token :token

  enum :access, { read: "read", write: "write" }, prefix: true, validate: true

  validates :name, presence: true
  validates :token, presence: true, uniqueness: true

  def self.authenticate(token)
    find_by(token: token)
  end

  def read_only?
    access_read?
  end
end
