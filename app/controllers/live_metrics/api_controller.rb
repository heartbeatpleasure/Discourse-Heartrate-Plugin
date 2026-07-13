# frozen_string_literal: true

module ::LiveMetrics
  class ApiController < ::ApplicationController
    USER_CARD_BATCH_LIMIT = 50
    LIVE_PAYLOAD_UNSET = Object.new.freeze

    requires_plugin ::LiveMetrics::PLUGIN_NAME

    skip_before_action :check_xhr, raise: false

    before_action :ensure_enabled
    before_action :ensure_logged_in, only: %i[me live_preview update_me update_account activate_account connect_hyperate disconnect_hyperate]
    before_action :ensure_logged_in, only: %i[plugin_config directory], if: -> { SiteSetting.live_metrics_require_login_to_view_page }
    before_action :ensure_can_view, only: %i[plugin_config me live_preview directory user_cards user]
    before_action :ensure_can_share, only: %i[update_me update_account activate_account connect_hyperate]

    # NOTE: do not name this action `config`; ActionController already has
    # a `config` method and Discourse plugin controllers can fail hard when
    # routes point at an action with that name. Keep the public URL as
    # /live-metrics/api/config, but route it to plugin_config internally.
    def plugin_config
      live_metrics_render_json(
        enabled: SiteSetting.live_metrics_enabled,
        directory_enabled: SiteSetting.live_metrics_directory_enabled,
        statistics_enabled: SiteSetting.live_metrics_statistics_enabled,
        database_ready: provider_accounts_table_ready?,
        poll_interval_seconds: SiteSetting.live_metrics_poll_interval_seconds.to_i,
        providers: provider_config_payload,
        visibility_options: visibility_options,
        permissions: {
          can_view: ::LiveMetrics::Permissions.can_view?(guardian),
          can_share: ::LiveMetrics::Permissions.can_share?(guardian)
        }
      )
    end

    def me
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      ensure_active_account_for_user!(current_user)
      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false))
    end

    def live_preview
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      account = active_current_account
      payload = {
        account: account ? account_payload(account, include_user: false, include_live: true, include_statistics: false, surface: :self) : nil,
        generated_at: Time.zone.now.iso8601
      }

      live_metrics_render_json(payload)
    end

    # Backwards-compatible settings endpoint. When no provider is supplied, the
    # active connected account is updated. Newer frontend code uses update_account
    # so multiple providers can be managed independently.
    def update_me
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      account = current_provider_account(params[:provider].presence || active_current_account&.provider || preferred_account_provider)
      return live_metrics_render_error("not_connected", status: 404) if account.blank?

      apply_account_settings!(account)
      return if performed?

      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false))
    end

    def update_account
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      provider = normalize_provider(params[:provider])
      return live_metrics_render_error("invalid_provider", status: 422) if provider.blank?

      account = current_provider_account(provider)
      return live_metrics_render_error("not_connected", status: 404) if account.blank?

      apply_account_settings!(account)
      return if performed?

      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false))
    end

    def activate_account
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      provider = normalize_provider(params[:provider])
      return live_metrics_render_error("invalid_provider", status: 422, message: "Choose a valid heartrate provider.") if provider.blank?

      account = current_provider_account(provider)
      return live_metrics_render_error("not_connected", status: 404, message: "Connect this provider before making it active.") if account.blank? || !account.connected?
      return live_metrics_render_error("provider_disabled", status: 404, message: "This provider is currently disabled.") unless ::LiveMetrics.enabled_provider_names.include?(provider)

      account.activate!
      ::LiveMetrics::RefreshCoordinator.sync_user(current_user.id)
      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false))
    rescue ActiveRecord::RecordInvalid => e
      live_metrics_render_error("activate_failed", status: 422, message: e.record.errors.full_messages.join(", ").presence || "The active provider could not be changed.")
    rescue => e
      Rails.logger.warn("[live_metrics] activate provider failed user_id=#{current_user&.id} provider=#{params[:provider]} error=#{e.class}: #{e.message}")
      live_metrics_render_error("activate_failed", status: 422, message: "The active provider could not be changed.")
    end

    def connect_hyperate
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?
      return live_metrics_render_error("hyperate_disabled", status: 404) unless SiteSetting.live_metrics_hyperate_enabled
      return live_metrics_render_error("hyperate_not_configured", status: 422, message: "HypeRate is enabled, but the API key is not configured yet.") unless ::LiveMetrics::HypeRateClient.configured?

      device_id = ::LiveMetrics::HypeRateClient.normalize_device_id(params[:device_id])
      return live_metrics_render_error("invalid_hyperate_device_id", status: 422, message: "Enter a valid HypeRate device ID.") unless ::LiveMetrics::HypeRateClient.valid_device_id?(device_id)

      account = ::LiveMetrics::ProviderAccount.find_or_initialize_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
      )

      if account.persisted? && ::LiveMetrics::RefreshCoordinator.async_enabled?
        ::LiveMetrics::RefreshCoordinator.stop(account, clear_fetch_lock: false)
      end

      account.provider_uid = device_id
      account.display_name = "HypeRate #{masked_device_id(device_id)}"
      account.profile_hash = { "device_id_last4" => device_id.last(4) }
      account.visibility ||= "private"
      account.show_on_profile = false if account.show_on_profile.nil?
      account.show_on_user_card = false if account.show_on_user_card.nil?
      account.show_in_directory = false if account.show_in_directory.nil?
      account.access_token_cipher = nil
      account.refresh_token_cipher = nil
      account.token_expires_at = nil
      account.scopes = nil
      account.last_error = nil
      account.save!
      account.activate!
      if ::LiveMetrics::RefreshCoordinator.async_enabled?
        ::LiveMetrics::RefreshCoordinator.start(account, replace: true)
      end
      ::LiveMetrics::RefreshCoordinator.sync_user(current_user.id)

      live_metrics_render_json(current_user_payload(include_live: false, include_statistics: false), status: 200)
    end

    def disconnect_hyperate
      return live_metrics_render_error("database_not_ready", status: 503, message: database_not_ready_message) unless provider_accounts_table_ready?

      account = ::LiveMetrics::ProviderAccount.find_by(
        user_id: current_user.id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
      )
      was_active = account&.active?
      ::LiveMetrics::RefreshCoordinator.stop(account) if account.present?
      account&.destroy!
      activate_fallback_account_for_user!(current_user) if was_active
      ::LiveMetrics::RefreshCoordinator.sync_user(current_user.id)

      live_metrics_render_json(disconnected: true)
    end

    def directory
      raise Discourse::NotFound unless SiteSetting.live_metrics_directory_enabled

      unless provider_accounts_table_ready?
        return live_metrics_render_json(users: [], generated_at: Time.zone.now.iso8601, database_ready: false)
      end

      accounts = ::LiveMetrics::ProviderAccount
        .enabled_providers
        .active
        .directory_enabled
        .includes(:user)
        .order(updated_at: :desc)
        .limit(SiteSetting.live_metrics_directory_limit.to_i)
        .to_a

      visible_accounts = accounts.select { |account| can_view_account?(account, surface: :directory) }
      live_by_account_id = live_payloads_for(visible_accounts)

      rows = visible_accounts.filter_map do |account|
        live = live_by_account_id[account.id]
        next unless directory_live_payload?(live)

        account_payload(
          account,
          include_user: true,
          include_live: true,
          include_statistics: false,
          surface: :directory,
          live_override: live,
        )
      end

      rows.sort_by! { |row| live_sort_key(row[:live]) }
      live_metrics_render_json(users: rows, generated_at: Time.zone.now.iso8601)
    end

    # Returns a deliberately minimal, batched payload for user-card surfaces.
    # Missing, stale, unauthorized, or non-opted-in readings are all omitted so
    # the response does not reveal whether a user has connected a provider.
    def user_cards
      unless provider_accounts_table_ready?
        return live_metrics_render_json(readings: [], generated_at: Time.zone.now.iso8601, database_ready: false)
      end

      popup_usernames = normalized_usernames_param(:usernames)
      directory_usernames = normalized_usernames_param(:directory_usernames)
      requested_usernames = (popup_usernames + directory_usernames).uniq.first(USER_CARD_BATCH_LIMIT)

      if requested_usernames.blank?
        return live_metrics_render_json(readings: [], generated_at: Time.zone.now.iso8601)
      end

      users_by_username = ::User
        .where(username_lower: requested_usernames)
        .select(:id, :username, :username_lower)
        .index_by(&:username_lower)

      accounts_by_user_id = ::LiveMetrics::ProviderAccount
        .enabled_providers
        .active
        .where(user_id: users_by_username.values.map(&:id))
        .includes(:user)
        .order(updated_at: :desc)
        .each_with_object({}) { |account, memo| memo[account.user_id] ||= account }

      visible_accounts = accounts_by_user_id.values.select do |account|
        username_lower = account.user&.username_lower
        next false if username_lower.blank?

        (popup_usernames.include?(username_lower) && can_view_account?(account, surface: :user_card)) ||
          (directory_usernames.include?(username_lower) && can_view_account?(account, surface: :directory))
      end
      live_by_account_id = live_payloads_for(visible_accounts)
      readings = []
      append_user_card_readings!(
        readings,
        popup_usernames,
        users_by_username,
        accounts_by_user_id,
        live_by_account_id,
        :user_card,
      )
      append_user_card_readings!(
        readings,
        directory_usernames,
        users_by_username,
        accounts_by_user_id,
        live_by_account_id,
        :directory,
      )

      live_metrics_render_json(readings: readings, generated_at: Time.zone.now.iso8601)
    end

    def user
      user = ::User.find_by(username_lower: params[:username].to_s.downcase)
      raise Discourse::NotFound if user.blank?

      account = ::LiveMetrics::ProviderAccount.enabled_providers.active.profile_enabled.find_by(user_id: user.id)
      raise Discourse::NotFound if account.blank? || !can_view_account?(account, surface: :profile)

      live_metrics_render_json(account_payload(account, include_user: true, include_live: true, include_statistics: true, surface: :profile))
    end

    private

    def live_metrics_render_json(payload = nil, status: 200, **keyword_payload)
      payload = keyword_payload if payload.nil?
      payload = {} if payload.nil?
      render json: payload, status: status
    end

    def live_metrics_render_error(error_key, status: 422, message: nil)
      live_metrics_render_json({ error: error_key, message: message || error_key }, status: status)
    end

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.live_metrics_enabled
    end

    def ensure_can_view
      raise Discourse::NotFound unless ::LiveMetrics::Permissions.can_view?(guardian)
    end

    def ensure_can_share
      return if ::LiveMetrics::Permissions.can_share?(guardian)

      live_metrics_render_error(
        "sharing_not_allowed",
        status: 403,
        message: "Your account is not allowed to connect or share heartrate data."
      )
    end

    def provider_config_payload
      {
        pulsoid: {
          enabled: SiteSetting.live_metrics_pulsoid_enabled,
          configured: ::LiveMetrics::PulsoidClient.configured?,
          connect_url: "/live-metrics/api/connect/pulsoid",
          connect_type: "oauth",
          label: "Pulsoid"
        },
        hyperate: {
          enabled: SiteSetting.live_metrics_hyperate_enabled,
          configured: ::LiveMetrics::HypeRateClient.configured?,
          connect_url: "/live-metrics/api/connect/hyperate",
          connect_type: "device_id",
          label: "HypeRate"
        }
      }
    end

    def current_provider_account(provider)
      provider = normalize_provider(provider)
      return nil if current_user.blank? || provider.blank? || !provider_accounts_table_ready?

      ::LiveMetrics::ProviderAccount.find_by(user_id: current_user.id, provider: provider)
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[live_metrics] provider account lookup failed user_id=#{current_user&.id} provider=#{provider} error=#{e.class}: #{e.message}")
      nil
    end

    def current_accounts
      return [] if current_user.blank? || !provider_accounts_table_ready?

      ::LiveMetrics::ProviderAccount
        .where(user_id: current_user.id, provider: ::LiveMetrics.enabled_provider_names)
        .order(active: :desc, updated_at: :desc, provider: :asc)
        .to_a
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[live_metrics] provider account lookup failed user_id=#{current_user&.id} error=#{e.class}: #{e.message}")
      []
    end

    def provider_accounts_table_ready?
      ::LiveMetrics::ProviderAccount.table_exists? &&
        %w[active show_on_user_card].all? { |column| ::LiveMetrics::ProviderAccount.column_names.include?(column) }
    rescue => e
      Rails.logger.warn("[live_metrics] provider account table check failed error=#{e.class}: #{e.message}")
      false
    end

    def current_user_payload(include_live:, include_statistics:)
      accounts = current_accounts.map do |account|
        account_payload(account, include_user: false, include_live: include_live && account.active?, include_statistics: include_statistics && account.active?, surface: :self)
      end

      active_account = accounts.find { |account| account[:active] } || accounts.first

      {
        user: user_payload(current_user),
        account: active_account,
        active_provider: active_account&.dig(:provider),
        accounts: accounts
      }
    end

    def preferred_account_provider
      current_accounts.first&.provider
    end

    def active_current_account
      ensure_active_account_for_user!(current_user)
      current_accounts.find(&:active?)
    end

    def ensure_active_account_for_user!(user)
      return if user.blank? || !provider_accounts_table_ready?

      accounts = ::LiveMetrics::ProviderAccount
        .where(user_id: user.id, provider: ::LiveMetrics.enabled_provider_names)
        .select(&:connected?)

      return if accounts.blank?
      return if accounts.any?(&:active?)

      activated = accounts.max_by(&:updated_at)&.activate!
      ::LiveMetrics::RefreshCoordinator.sync_user(user.id) if activated.present?
    rescue => e
      Rails.logger.warn("[live_metrics] active provider check failed user_id=#{user&.id} error=#{e.class}: #{e.message}")
    end

    def activate_fallback_account_for_user!(user)
      return if user.blank? || !provider_accounts_table_ready?

      fallback = ::LiveMetrics::ProviderAccount
        .where(user_id: user.id, provider: ::LiveMetrics.enabled_provider_names)
        .order(updated_at: :desc)
        .detect(&:connected?)
      fallback&.activate!
    rescue => e
      Rails.logger.warn("[live_metrics] fallback provider activation failed user_id=#{user&.id} error=#{e.class}: #{e.message}")
    end

    def account_payload(
      account,
      include_user:,
      include_live:,
      include_statistics:,
      surface:,
      live_override: LIVE_PAYLOAD_UNSET
    )
      live =
        if include_live
          live_override.equal?(LIVE_PAYLOAD_UNSET) ? live_payload(account) : live_override
        end
      payload = {
        provider: account.provider,
        provider_label: provider_label(account.provider),
        display_name: account.display_name.presence || default_display_name(account.provider),
        connected: account.connected?,
        active: account.active?,
        visibility: account.visibility,
        show_on_profile: account.show_on_profile,
        show_on_user_card: account.show_on_user_card,
        show_in_directory: account.show_in_directory,
        live: live,
        status_label: status_label(live),
        profile: public_profile_payload(account)
      }

      payload[:user] = user_payload(account.user) if include_user

      if include_statistics && account.pulsoid? && SiteSetting.live_metrics_statistics_enabled && account.scopes_list.include?(::LiveMetrics::PulsoidClient::STATISTICS_SCOPE)
        payload[:statistics] = {
          "24h" => ::LiveMetrics::PulsoidClient.statistics(account, time_range: "24h"),
          "7d" => ::LiveMetrics::PulsoidClient.statistics(account, time_range: "7d"),
          "30d" => ::LiveMetrics::PulsoidClient.statistics(account, time_range: "30d")
        }
      end

      payload
    end

    def live_payload(account)
      if async_current_readings?
        return decorate_async_live_payload(
          account,
          ::LiveMetrics::CurrentStateStore.read(account),
        )
      end

      legacy_live_payload(account)
    end

    def live_payloads_for(accounts)
      accounts = Array(accounts).compact.uniq { |account| account.id }
      return {} if accounts.blank?

      if async_current_readings?
        states = ::LiveMetrics::CurrentStateStore.read_many(accounts)
        return accounts.each_with_object({}) do |account, result|
          result[account.id] = decorate_async_live_payload(account, states[account.id])
        end
      end

      accounts.index_with { |account| legacy_live_payload(account) }
    end

    def legacy_live_payload(account)
      case account.provider
      when ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
        ::LiveMetrics::PulsoidClient.latest(account)
      when ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
        ::LiveMetrics::HypeRateClient.latest(account)
      else
        { status: "unavailable", heart_rate: nil, measured_at: nil, measured_at_ms: nil }
      end
    end

    def decorate_async_live_payload(account, state)
      live =
        if state.present?
          state.dup
        else
          {
            status: "no_data",
            heart_rate: nil,
            measured_at: nil,
            measured_at_ms: nil,
            age_seconds: nil,
            error_code: "no_data",
          }
        end

      error = async_live_error(account.provider, live[:status])
      live[:error] = error if error.present?
      live
    end

    def async_live_error(provider, status)
      case status.to_s
      when "unauthorized"
        provider.to_s == ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE ?
          "HypeRate rejected the connection. Check the API key and device ID." :
          "Pulsoid authorization has expired. Reconnect your Pulsoid account."
      when "unavailable"
        "#{provider_label(provider)} data is temporarily unavailable."
      end
    end

    def async_current_readings?
      ::LiveMetrics::RefreshCoordinator.async_enabled?
    end

    def user_payload(user)
      {
        id: user.id,
        username: user.username,
        name: user.name,
        avatar_template: user.avatar_template,
        profile_url: "/u/#{user.username}",
        profile_details: public_user_profile_details(user)
      }
    end

    PROFILE_DETAIL_ALIASES = {
      "age" => %w[age leeftijd birthdate birthday dateofbirth geboortedatum],
      "gender" => %w[gender geslacht]
    }.freeze

    PROFILE_DETAIL_LABELS = {
      "age" => "Age",
      "gender" => "Gender"
    }.freeze

    def public_user_profile_details(user)
      return [] if user.blank? || !defined?(::UserField)

      fields_by_key = profile_detail_user_fields
      return [] if fields_by_key.blank?

      custom_fields = user.custom_fields || {}
      fields_by_key.filter_map do |key, field|
        raw_value = custom_fields["user_field_#{field.id}"]
        next if raw_value.blank?

        value = public_profile_detail_value(key, raw_value)
        next if value.blank?

        { key: key, label: PROFILE_DETAIL_LABELS[key] || field.name.to_s, value: value }
      end
    rescue => e
      Rails.logger.warn("[live_metrics] public profile detail lookup failed user_id=#{user&.id} error=#{e.class}: #{e.message}")
      []
    end

    def profile_detail_user_fields
      @profile_detail_user_fields ||= begin
        fields = ::UserField.all.to_a
        fields.each_with_object({}) do |field, memo|
          next unless public_profile_detail_field?(field)

          key = normalized_profile_detail_key(field.name)
          next if key.blank? || memo.key?(key)

          memo[key] = field
        end.sort_by { |key, _| PROFILE_DETAIL_LABELS.keys.index(key) || 99 }.to_h
      end
    rescue => e
      Rails.logger.warn("[live_metrics] profile detail user field lookup failed error=#{e.class}: #{e.message}")
      {}
    end

    def public_profile_detail_field?(field)
      visible_on_card =
        (field.respond_to?(:show_on_user_card) && field.show_on_user_card) ||
        (field.respond_to?(:show_on_user_card?) && field.show_on_user_card?)
      visible_on_profile =
        (field.respond_to?(:show_on_profile) && field.show_on_profile) ||
        (field.respond_to?(:show_on_profile?) && field.show_on_profile?)

      visible_on_card || visible_on_profile
    end

    def normalized_profile_detail_key(name)
      normalized = name.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
      compact = normalized.gsub(/\s+/, "")

      PROFILE_DETAIL_ALIASES.find do |_, aliases|
        aliases.any? { |profile_alias| profile_alias == compact || profile_alias == normalized }
      end&.first
    end

    def public_profile_detail_value(key, raw_value)
      value = raw_value.to_s.strip
      return nil if value.blank?

      case key.to_s
      when "age"
        public_age_value(value)
      when "gender"
        value
      else
        nil
      end
    end

    def public_age_value(value)
      return value if value.match?(/\A\d{1,3}\z/)
      return nil unless value.match?(/\d{4}/)

      parsed_date = Date.parse(value)
      today = Date.current
      age = today.year - parsed_date.year
      age -= 1 if today < parsed_date.change(year: today.year)

      age.between?(0, 120) ? age.to_s : nil
    rescue ArgumentError, TypeError
      nil
    end

    def public_profile_payload(account)
      profile = account.profile_hash
      payload = {
        channel: profile["channel"],
        heart_rate_available: profile["heart_rate"] == true
      }
      payload[:device_id_last4] = profile["device_id_last4"] if account.hyperate?
      payload
    end

    def apply_account_settings!(account)
      visibility = params[:visibility].to_s
      if visibility.present?
        allowed_visibility_ids = ::LiveMetrics::Permissions.visibility_option_ids
        unless ::LiveMetrics::ProviderAccount::VISIBILITIES.include?(visibility) && allowed_visibility_ids.include?(visibility)
          return live_metrics_render_error("invalid_visibility", status: 422, message: "Choose an available visibility option.")
        end

        account.visibility = visibility
      end

      account.show_on_profile = boolean_param(:show_on_profile, default: account.show_on_profile)
      account.show_on_user_card = boolean_param(:show_on_user_card, default: account.show_on_user_card)
      account.show_in_directory = boolean_param(:show_in_directory, default: account.show_in_directory)
      account.save!
    rescue ActiveRecord::RecordInvalid => e
      live_metrics_render_error("settings_save_failed", status: 422, message: e.record.errors.full_messages.join(", ").presence || "Your heartrate settings could not be saved.")
    rescue => e
      Rails.logger.warn("[live_metrics] account settings save failed account_id=#{account&.id} error=#{e.class}: #{e.message}")
      live_metrics_render_error("settings_save_failed", status: 422, message: "Your heartrate settings could not be saved.")
    end

    def can_view_account?(account, surface:)
      return false unless account&.connected?
      return false unless account.active?
      return false unless ::LiveMetrics.enabled_provider_names.include?(account.provider)

      case surface
      when :directory
        return false unless account.show_in_directory
      when :profile
        return false unless account.show_on_profile
      when :user_card
        return false unless account.show_on_user_card
      end

      return true if current_user&.staff?
      return true if current_user.present? && account.user_id == current_user.id
      return false unless ::LiveMetrics::Permissions.can_share_user?(account.user)

      case account.visibility
      when "public"
        SiteSetting.live_metrics_allow_anonymous_public_view || current_user.present?
      when "logged_in"
        current_user.present?
      when "staff"
        current_user&.staff?
      else
        false
      end
    end

    def normalized_usernames_param(key)
      raw_values = params[key]
      values = raw_values.is_a?(Array) ? raw_values : [raw_values]

      values
        .compact
        .flat_map { |value| value.to_s.split(/[|,\n]/) }
        .map { |value| value.to_s.strip.downcase }
        .reject(&:blank?)
        .uniq
        .first(USER_CARD_BATCH_LIMIT)
    end

    def append_user_card_readings!(
      rows,
      usernames,
      users_by_username,
      accounts_by_user_id,
      live_by_account_id,
      surface
    )
      usernames.each do |username_lower|
        user = users_by_username[username_lower]
        next if user.blank?

        account = accounts_by_user_id[user.id]
        next unless can_view_account?(account, surface: surface)

        live = live_by_account_id[account.id]
        next unless directory_live_payload?(live)
        next unless live[:heart_rate].to_i.positive?

        rows << user_card_live_payload(user, live, surface)
      end
    end

    def user_card_live_payload(user, live, surface)
      measured_at_ms = live[:measured_at_ms].to_i
      if measured_at_ms <= 0 && live[:measured_at].present?
        parsed_measured_at = Time.zone.parse(live[:measured_at].to_s)
        measured_at_ms = (parsed_measured_at.to_f * 1000).to_i if parsed_measured_at
      end
      if measured_at_ms <= 0 && live[:age_seconds].present?
        measured_at_ms = ((Time.zone.now.to_f - live[:age_seconds].to_i) * 1000).to_i
      end

      expires_at_ms =
        if measured_at_ms.positive?
          measured_at_ms + (SiteSetting.live_metrics_live_threshold_seconds.to_i * 1000)
        end

      {
        username: user.username_lower,
        surface: surface.to_s,
        heart_rate: live[:heart_rate].to_i,
        measured_at: live[:measured_at],
        measured_at_ms: measured_at_ms.positive? ? measured_at_ms : nil,
        age_seconds: live[:age_seconds],
        expires_at_ms: expires_at_ms
      }
    rescue ArgumentError, TypeError, NoMethodError
      {
        username: user.username_lower,
        surface: surface.to_s,
        heart_rate: live[:heart_rate].to_i,
        measured_at: live[:measured_at],
        measured_at_ms: live[:measured_at_ms],
        age_seconds: live[:age_seconds],
        expires_at_ms: nil
      }
    end

    def visibility_options
      ::LiveMetrics::Permissions.visibility_option_ids.map do |id|
        { id: id, label: visibility_label(id) }
      end
    end

    def visibility_label(id)
      case id.to_s
      when "private"
        "Only me"
      when "logged_in"
        "Logged-in users"
      when "public"
        "Public"
      when "staff"
        "Staff only"
      else
        id.to_s.titleize
      end
    end

    def boolean_param(key, default:)
      return default unless params.key?(key)

      ActiveModel::Type::Boolean.new.cast(params[key])
    end

    def status_label(live)
      case live&.dig(:status).to_s
      when "live"
        "Live"
      when "delayed"
        "Delayed"
      when "stale"
        "No recent signal"
      when "no_data"
        "No heart-rate data yet"
      when "unauthorized"
        "Reconnect required"
      else
        "Unavailable"
      end
    end

    def directory_live_payload?(live)
      live&.dig(:status).to_s == "live" && live&.dig(:heart_rate).present?
    end

    def live_sort_key(live)
      status = live&.dig(:status).to_s
      status_rank = { "live" => 0, "delayed" => 1, "stale" => 2, "no_data" => 3, "unauthorized" => 4, "unavailable" => 5 }[status] || 9
      age = live&.dig(:age_seconds).to_i
      [status_rank, age]
    end

    def provider_label(provider)
      case provider.to_s
      when ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
        "Pulsoid"
      when ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
        "HypeRate"
      else
        provider.to_s.titleize
      end
    end

    def default_display_name(provider)
      "#{provider_label(provider)} account"
    end

    def normalize_provider(provider)
      provider = provider.to_s.downcase.strip
      ::LiveMetrics::ProviderAccount::PROVIDERS.include?(provider) ? provider : nil
    end

    def masked_device_id(device_id)
      value = device_id.to_s
      return "device" if value.blank?
      return "device #{value}" if value.length <= 8

      "device #{value.first(4)}…#{value.last(4)}"
    end

    def database_not_ready_message
      "The Heartrate database table is not ready yet. Run Discourse migrations and rebuild/restart."
    end
  end
end
