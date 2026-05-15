# frozen_string_literal: true

module ::LiveMetrics
  class TokenCipher
    PURPOSE = "live_metrics_provider_tokens"

    def self.encrypt(value)
      str = value.to_s
      return nil if str.blank?

      encryptor.encrypt_and_sign(str, purpose: PURPOSE)
    end

    def self.decrypt(value)
      str = value.to_s
      return nil if str.blank?

      encryptor.decrypt_and_verify(str, purpose: PURPOSE)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage
      nil
    end

    def self.encryptor
      @encryptor ||= begin
        key = Rails.application.key_generator.generate_key("live_metrics/token_cipher", 32)
        ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
      end
    end
  end
end
