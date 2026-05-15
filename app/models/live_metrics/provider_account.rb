# frozen_string_literal: true

module ::LiveMetrics
  class ProviderAccount < ::ActiveRecord::Base
    self.table_name = "live_metrics_provider_accounts"

    PROVIDER_PULSOID = "pulsoid"
    PROVIDER_HYPERATE = "hyperate"
    PROVIDERS = [PROVIDER_PULSOID, PROVIDER_HYPERATE]
    VISIBILITIES = %w[private logged_in public staff]

    belongs_to :user

    validates :provider, presence: true, inclusion: { in: PROVIDERS }
    validates :visibility, presence: true, inclusion: { in: VISIBILITIES }
    validates :user_id, uniqueness: { scope: :provider }
    validates :provider_uid, presence: true, if: :hyperate?

    scope :pulsoid, -> { where(provider: PROVIDER_PULSOID) }
    scope :hyperate, -> { where(provider: PROVIDER_HYPERATE) }
    scope :enabled_providers, -> { where(provider: ::LiveMetrics.enabled_provider_names) }
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
      if pulsoid?
        access_token_cipher.present? && refresh_token_cipher.present?
      elsif hyperate?
        provider_uid.present?
      else
        false
      end
    end

    def pulsoid?
      provider == PROVIDER_PULSOID
    end

    def hyperate?
      provider == PROVIDER_HYPERATE
    end

    def token_refresh_recommended?
      token_expires_at.blank? || token_expires_at <= 2.minutes.from_now
    end

    def scopes_list
      scopes.to_s.split(/\s+/).reject(&:blank?)
    end
  end
end
