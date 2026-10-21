class Restaurant < ApplicationRecord
  validates :name, presence: true
  validates :code, presence: true, uniqueness: true, format: { with: /\A[A-Z]+\z/ }
  validates :dispatch_url, presence: true, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) }
end
