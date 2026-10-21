class Restaurant < ApplicationRecord
  has_many :orders, dependent: :restrict_with_error

  validates :name, presence: true
  validates :code, presence: true, uniqueness: true, format: { with: /\A[A-Z]+\z/ }
  validates :dispatch_url, presence: true, http_url: true
end
