# frozen_string_literal: true

module Bible270
  class ScriptureFrame < ApplicationRecord
    self.table_name = 'bible270_scripture_frames'

    scope :enabled, -> { where(enabled: true) }

    before_validation :normalize_fields

    before_validation :assign_translation_attribution, unless: :disabling_only?

    validates :reference, presence: true, length: { maximum: 200 }
    validates :text, presence: true, length: { maximum: 4000 }
    validates :translation, presence: true, length: { maximum: 40 }
    validates :translation, inclusion: {
      in: ->(_frame) { ScriptureFrames.translations },
      message: 'is unsupported; add translation and attribution to YAML'
    }, allow_blank: true, unless: :disabling_only?
    validates :attribution, length: { maximum: 500 }, allow_nil: true
    validates :enabled, inclusion: { in: [true, false] }

    def attribution
      # A registered nil credit is authoritative; only retired translations use stored credit.
      ScriptureFrames.translation_attributions.fetch(translation.to_s.strip.upcase) { super }
    end

  private

    def disabling_only?
      persisted? && will_save_change_to_enabled?(from: true, to: false) && changed_attribute_names_to_save == ['enabled']
    end

    def normalize_fields
      %i[reference text translation].each do |field|
        value = public_send(field)
        public_send("#{field}=", value.gsub("\r\n", "\n").strip) if value.is_a?(String)
      end
      self.translation = translation.upcase if translation.is_a?(String)
    end

    def assign_translation_attribution
      self.attribution = ScriptureFrames.attribution_for(translation)
    end
  end
end
