# frozen_string_literal: true

require 'yaml'
require 'bible270/translations'

module Bible270
  module ScriptureFrames
    Entry = Struct.new(:id, :reference, :translation, :text, :attribution, keyword_init: true)
    BUNDLED_PATH = File.expand_path('../../config/scripture_frames.yml', __dir__)
    LIMITS = { 'reference' => 200, 'translation' => 40, 'text' => 4000, 'attribution' => 500 }.freeze
    DISABLED_DEFAULT_PREFIX = 'scripture-frame-disabled:'
    DEFAULT_ID_PATTERN = %r{\Adefault:[a-z0-9]+(?:-[a-z0-9]+)*\z}
    DEFAULT_SETTINGS_UNAVAILABLE = 'Default Scripture frame settings are unavailable. Connect the database and run pending migrations, then try again.'
    # Translation choices need not have a passage in the bundled catalog.
    ADDITIONAL_ATTRIBUTIONS = {
      'LSB' => 'LSB © 2021 The Lockman Foundation.',
      'KJV' => nil,
      'CSB' => 'CSB © 2017 Holman Bible Publishers.',
      'NIV' => 'NIV © 1973, 1978, 1984, 2011 Biblica, Inc.',
      'YLT' => nil
    }.freeze
    private_constant :BUNDLED_PATH, :LIMITS, :ADDITIONAL_ATTRIBUTIONS,
                     :DISABLED_DEFAULT_PREFIX, :DEFAULT_ID_PATTERN, :DEFAULT_SETTINGS_UNAVAILABLE

  module_function

    def defaults
      bundled = load_catalog(BUNDLED_PATH)
      path = Bible270.config.scripture_frames_path
      return bundled if path.nil?

      begin
        entries = load_catalog(path)
        metadata = catalog_attributions(bundled + entries)
        entries.each { |entry| entry.attribution = metadata[entry.translation] }
      rescue Psych::Exception, SystemCallError, IOError, ArgumentError, EncodingError => e
        # Do not log YAML contents, host paths, or parser messages containing input.
        Rails.logger.warn("[bible270] invalid Scripture frame catalog (#{e.class}); using bundled defaults") if defined?(Rails) && Rails.logger
        bundled
      end
    end

    def translation_attributions
      catalog_attributions(load_catalog(BUNDLED_PATH) + defaults)
    end

    def translations
      available = translation_attributions.keys
      preference_order = Translations.codes + Translations::VERSIONS.keys + ADDITIONAL_ATTRIBUTIONS.keys
      ordered = preference_order.uniq & available
      ordered + (available - ordered).sort
    end

    def attribution_for(code)
      translation_attributions[code.to_s.strip.upcase]
    end

    def custom_available?
      return false unless defined?(Bible270::ScriptureFrame)

      Bible270::ScriptureFrame.table_exists?
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
      false
    end

    def default_settings_available?
      return false unless defined?(Bible270::Setting)

      Bible270::Setting.table_exists?
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      false
    end

    def disabled_default_ids
      return [] unless default_settings_available?

      Bible270::Setting.where('key LIKE ?', "#{DISABLED_DEFAULT_PREFIX}%").pluck(:key, :value).filter_map do |key, value|
        id = key.delete_prefix(DISABLED_DEFAULT_PREFIX)
        id if value == 'true' && id.match?(DEFAULT_ID_PATTERN)
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      []
    end

    def set_default_enabled!(id, enabled:)
      unless id.is_a?(String) && defaults.any? { |frame| frame.id == id }
        raise ArgumentError, 'Unknown default Scripture frame ID'
      end
      raise ArgumentError, 'enabled must be true or false' unless true.equal?(enabled) || false.equal?(enabled)
      raise ArgumentError, DEFAULT_SETTINGS_UNAVAILABLE unless default_settings_available?

      key = "#{DISABLED_DEFAULT_PREFIX}#{id}"
      if enabled
        Bible270::Setting.where(key: key).delete_all
      else
        default_disable_setting(key).update!(value: 'true')
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      raise ArgumentError, DEFAULT_SETTINGS_UNAVAILABLE, cause: nil
    end

    def default_disable_setting(key)
      Bible270::Setting.find_by(key: key) || Bible270::Setting.create_or_find_by!(key: key) { |setting| setting.value = 'true' }
    rescue ActiveRecord::RecordInvalid => e
      # The uniqueness validator can observe a concurrent insert before the DB constraint does.
      raise unless e.record.errors.of_kind?(:key, :taken)

      Bible270::Setting.find_by!(key: key)
    end
    private_class_method :default_disable_setting

    def random(exclude: nil)
      disabled_ids = disabled_default_ids
      pool = defaults.reject { |frame| disabled_ids.include?(frame.id) }
      if custom_available?
        pool += Bible270::ScriptureFrame.enabled.map do |frame|
          Entry.new(id: "custom:#{frame.id}", reference: frame.reference,
                    translation: frame.translation, text: frame.text, attribution: frame.attribution)
        end
      end
      pool = pool.reject { |frame| frame.id == exclude } if pool.length > 1 && exclude.is_a?(String)
      pool.sample
    end

    def load_catalog(path)
      source = File.read(path, encoding: 'UTF-8')
      raise ArgumentError, 'ERB is not supported' if source.include?('<%')

      rows = YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: false)
      raise ArgumentError, 'Expected a list of Scripture frames' unless rows.is_a?(Array)

      entries = rows.map { |row| build_entry(row) }
      raise ArgumentError, 'Duplicate Scripture frame IDs' unless entries.map(&:id).uniq.length == entries.length

      catalog_attributions(entries)
      entries
    end
    private_class_method :load_catalog

    def catalog_attributions(entries)
      entries.each_with_object(ADDITIONAL_ATTRIBUTIONS.dup) do |entry, metadata|
        existing = metadata[entry.translation]
        if existing && entry.attribution && existing != entry.attribution
          raise ArgumentError, 'Conflicting translation attributions'
        end

        metadata[entry.translation] = existing || entry.attribution
      end
    end
    private_class_method :catalog_attributions

    def build_entry(row)
      raise ArgumentError, 'Expected a Scripture frame mapping' unless row.is_a?(Hash)
      raise ArgumentError, 'Unknown Scripture frame fields' unless (row.keys - (LIMITS.keys + ['id'])).empty?

      id = row['id']
      raise ArgumentError, 'Expected a stable slug ID' unless id.is_a?(String) && id.match?(%r{\A[a-z0-9]+(?:-[a-z0-9]+)*\z})

      attributes = LIMITS.to_h do |field, maximum|
        [field.to_sym, normalize_field(row[field], field, maximum)]
      end
      Entry.new(id: "default:#{id}", **attributes)
    end
    private_class_method :build_entry

    def normalize_field(value, field, maximum)
      return nil if field == 'attribution' && value.nil?

      raise ArgumentError, 'Expected plaintext fields' unless value.is_a?(String)

      value = value.gsub("\r\n", "\n").strip
      value = value.upcase if field == 'translation'
      raise ArgumentError, 'Invalid Scripture frame field length' if value.length > maximum || (field != 'attribution' && value.empty?)

      field == 'attribution' && value.empty? ? nil : value
    end
    private_class_method :normalize_field
  end
end
