# frozen_string_literal: true

require 'yaml'
require 'bible270/translations'

module Bible270
  module ScriptureFrames
    Entry = Struct.new(:id, :reference, :translation, :text, :attribution, keyword_init: true)
    BUNDLED_PATH = File.expand_path('../../config/scripture_frames.yml', __dir__)
    LIMITS = { 'reference' => 200, 'translation' => 40, 'text' => 4000, 'attribution' => 500 }.freeze
    # Translation choices need not have a passage in the bundled catalog.
    ADDITIONAL_ATTRIBUTIONS = {
      'LSB' => 'LSB © 2021 The Lockman Foundation.',
      'KJV' => nil,
      'CSB' => 'CSB © 2017 Holman Bible Publishers.',
      'NIV' => 'NIV © 1973, 1978, 1984, 2011 Biblica, Inc.',
      'YLT' => nil
    }.freeze
    private_constant :BUNDLED_PATH, :LIMITS, :ADDITIONAL_ATTRIBUTIONS

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

    def random(exclude: nil)
      pool = defaults
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
