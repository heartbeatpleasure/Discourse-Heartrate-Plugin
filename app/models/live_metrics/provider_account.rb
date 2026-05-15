# frozen_string_literal: true

module ::LiveMetrics
  class ProviderAccount < ::ActiveRecord::Base
    self.table_name = "live_metrics_provider_accounts"

    PROVIDER_PULSOID = "pulsoid"
    PROVIDERS = [PROVIDER_PULSOID]
    VISIBILITIES = %w[private logged_in public staff]

    belongs_to :user

    validates :provider, presence: true, inclusion: { in: PROVIDERS }
    validates :visibility, presence: true, inclusion: { in: VISIBILITIES }
    validates :user_id, uniqueness: { scope: :provider }

    scope :pulsoid, -> { where(provider: PROVIDER_PULSOID) }
    scope :directory_enabled, -> { where(show_in_directory: true) }
    scope :profile_enabled, -> { where(show_on_profile: true) }

    def access_token
      ::LiveMetrics::TokenCipher.decrypt(access_token_cipher)
    end

    def access_token=(value)
      self.access_token_cipher = ::LiveMetrics::TokenCipher.encrypt(value)
    end

    def refresh_token
      ::LiveMetrics::TokenCipher.decrypt(refresh_token_cipher)
    end

    def refresh_token=(value)
      self.refresh_token_cipher = ::LiveMetrics::TokenCipher.encrypt(value)
    end

    def profile_hash
      JSON.parse(profile_data.to_s.presence || "{}")
    rescue JSON::ParserError
      {}
    end

    def profile_hash=(value)
      self.profile_data = (value || {}).to_json
    end

    def connected?
      access_token_cipher.present? && refresh_token_cipher.present?
    end

    def pulsoid?
      provider == PROVIDER_PULSOID
    end

    def token_refresh_recommended?
      token_expires_at.blank? || token_expires_at <= 2.minutes.from_now
    end

    def scopes_list
      scopes.to_s.split(/\s+/).reject(&:blank?)
    end
  end
end
