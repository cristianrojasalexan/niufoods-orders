# Validates that the whole value is an absolute HTTP(S) URL with a host.
#
#   validates :dispatch_url, http_url: true
class HttpUrlValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    record.errors.add(attribute, :invalid_url) unless valid_url?(value)
  end

  private

  def valid_url?(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end
end
