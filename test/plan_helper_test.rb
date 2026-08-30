# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class PlanHelperTest < ActionView::TestCase
    include Bible270::PlanHelper

    def setup
      needs_rails!
      clear_engine_tables!
      @previous_from = Bible270.config.mailer_from
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'h@example.org',
                                         email: 'h@example.org', display_name: 'Helen Helper',
                                         first_name: 'Helen', last_name: 'Helper')
    end

    def teardown
      Bible270.config.mailer_from = @previous_from
      Bible270.config.favicon = nil
      Bible270.config.footer = nil
      Bible270.config.footer_html = nil
      Bible270.config.header_mark = nil
    end

    # The helper asks current_reader for the translation; in a view test there is
    # no controller, so stand one in.
    attr_reader :current_reader

    def signed_in? = !@current_reader.nil?

    def test_track_metadata
      assert_equal 'Old Testament', b270_track('ot')[:label]
      assert_equal 'New Testament', b270_track('nt')[:label]
      refute_nil b270_track('pp')[:label]
    end

    def test_provider_labels
      assert_equal 'GitHub', b270_provider_label('github')
      assert_equal 'GitLab', b270_provider_label('gitlab')
      # Anything unrecognised is titleised rather than shown raw.
      assert_equal 'Church Directory', b270_provider_label('church_directory')
    end

    def test_the_passage_url_uses_bible_com_for_a_visitor
      @current_reader = nil

      assert_equal 'https://www.bible.com/bible/114/GEN.1.NKJV',
                   b270_passage_url('Genesis 1')
    end

    def test_the_passage_url_follows_the_readers_gateway_choice
      @reader.update_bible_version('NASB95')
      @reader.update!(passage_source: 'bible_gateway')
      @current_reader = @reader

      # NASB95 is 'NASB1995' to Bible Gateway; sending the display code would
      # land on a search page.
      assert_includes b270_passage_url('Genesis 1'), 'NASB1995'
    end

    def test_blue_letter_bible_links_follow_the_readers_choice
      @reader.update_bible_version('KJV')
      @reader.update!(passage_source: 'blue_letter_bible')
      @current_reader = @reader

      assert_equal 'https://www.blueletterbible.org/kjv/gen/1/1/s_1001',
                   b270_passage_url("Genesis 1\u20133")
      assert_equal 'https://www.blueletterbible.org/kjv/mat/1/1/s_930001',
                   b270_passage_url('Matthew 1')
    end

    def test_bible_com_links_follow_the_readers_choice
      @reader.update_bible_version('KJV')
      @reader.update!(passage_source: 'bible_com')
      @current_reader = @reader

      assert_equal 'https://www.bible.com/bible/1/GEN.1.KJV',
                   b270_passage_url("Genesis 1\u20133")
      assert_equal 'https://www.bible.com/bible/1/MAT.1.KJV',
                   b270_passage_url('Matthew 1')
    end

    def test_original_language_links_can_use_blue_letter_bible
      @reader.update_bible_version('HEB/GRK')
      @reader.update!(passage_source: 'blue_letter_bible')
      @current_reader = @reader

      assert_equal 'https://www.blueletterbible.org/wlc/gen/1/1/s_1001',
                   b270_passage_url("Genesis 1\u20133")
      assert_equal 'https://www.blueletterbible.org/mgnt/mat/1/1/s_930001',
                   b270_passage_url('Matthew 1')
    end

    def test_original_language_links_can_use_bible_com
      @reader.update_bible_version('HEB/GRK')
      @reader.update!(passage_source: 'bible_com')
      @current_reader = @reader

      assert_equal 'https://www.bible.com/bible/3585/GEN.1.WLC',
                   b270_passage_url("Genesis 1\u20133")
      assert_equal 'https://www.bible.com/bible/2270/MAT.1.THGNT',
                   b270_passage_url('Matthew 1')
    end

    def test_all_greek_links_can_use_blue_letter_bible
      @reader.update_bible_version('ALLGRK')
      @reader.update!(passage_source: 'blue_letter_bible')
      @current_reader = @reader

      assert_equal 'https://www.blueletterbible.org/mgnt/gen/1/1/s_1001',
                   b270_passage_url('Genesis 1')
      assert_equal 'https://www.blueletterbible.org/mgnt/mat/1/1/s_930001',
                   b270_passage_url('Matthew 1')
    end

    def test_all_greek_links_can_use_bible_com
      @reader.update_bible_version('ALLGRK')
      @reader.update!(passage_source: 'bible_com')
      @current_reader = @reader

      assert_equal 'https://www.bible.com/bible/2503/GEN.1.GRCBRENT',
                   b270_passage_url('Genesis 1')
      assert_equal 'https://www.bible.com/bible/2270/MAT.1.THGNT',
                   b270_passage_url('Matthew 1')
    end

    def test_a_blank_reference_produces_no_link
      assert_equal '#', b270_passage_url('')
      assert_equal '#', b270_passage_url(nil)
    end

    def test_passage_links_reuse_one_trusted_scripture_tab
      link = b270_passage_link('Genesis 1', class: 'reading')

      assert_includes link, 'target="bible270_scripture"'
      assert_includes link, 'class="reading"'
      assert_includes link, 'rel="noopener"'
      assert_includes link, 'data-b270-passage-link="true"'
      refute_includes link, 'target="_blank"'
    end

    def test_the_version_tag
      @current_reader = nil
      tag = b270_version_tag

      assert_includes tag, Bible270.config.bible_version
      assert_includes tag, 'b270-version'
    end

    def test_original_language_version_tags_name_the_track_language
      @reader.update_bible_version('HEB/GRK')
      @current_reader = @reader

      assert_includes b270_version_tag(track: 'ot'), '(Hebrew)'
      assert_includes b270_version_tag(track: 'pp'), '(Hebrew)'
      assert_includes b270_version_tag(track: 'nt'), '(Greek)'
    end

    def test_all_greek_version_tags_name_every_track_greek
      @reader.update_bible_version('ALLGRK')
      @current_reader = @reader

      %w[ot pp nt].each do |track|
        assert_includes b270_version_tag(track: track), '(Greek)'
      end
    end

    def test_the_favicon_is_a_data_uri_by_default
      assert_includes b270_favicon_tag, 'data:image/svg+xml'
    end

    def test_the_favicon_can_be_replaced_or_removed
      Bible270.config.favicon = '/icons/mine.svg'
      assert_includes b270_favicon_tag, '/icons/mine.svg'

      Bible270.config.favicon = false
      assert_nil b270_favicon_tag
    end

    def test_the_header_mark_is_the_built_in_loaf_by_default
      mark = b270_mark

      assert_includes mark, '<svg'
      assert_includes mark, 'b270-mark'
      refute_includes mark, '%23', 'inline SVG must not be percent-encoded'
    end

    def test_the_header_mark_takes_a_size
      assert_includes b270_mark(size: 48), "width='48'"
    end

    def test_a_host_can_supply_its_own_mark
      Bible270.config.header_mark = '/logo.png'

      assert_includes b270_mark, '/logo.png'
      assert_includes b270_mark, 'b270-mark'
    end

    def test_a_host_can_remove_the_mark
      Bible270.config.header_mark = false
      assert_nil b270_mark
    end

    def test_the_avatar_falls_back_to_initials
      @reader.update!(avatar_url: nil)

      assert_nil b270_avatar_src(@reader)
      assert_includes b270_avatar(@reader), @reader.initials
    end

    def test_a_provider_avatar_is_used_when_present
      @reader.update!(avatar_url: 'https://example.org/face.png')

      assert_equal 'https://example.org/face.png', b270_avatar_src(@reader)
      assert_includes b270_avatar(@reader), 'face.png'
    end

    def test_day_status_reflects_progress
      assert_equal '', b270_day_status_class(nil, 1), 'a visitor has no status'
      assert_equal '', b270_day_status_class(@reader, 1)

      @reader.checkoffs.create!(day: 1, track: 'nt')
      assert_equal 'partial', b270_day_status_class(@reader.reload_progress, 1)

      @reader.mark_day_complete!(1)
      assert_equal 'complete', b270_day_status_class(@reader.reload_progress, 1)
    end

    def test_the_footer_can_be_replaced_or_removed
      Bible270.config.footer_html = '<p>Mine</p>'
      assert_includes b270_footer, 'Mine'

      Bible270.config.footer = false
      assert_nil b270_footer
    end
  end
end
