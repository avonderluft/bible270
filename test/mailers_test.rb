# frozen_string_literal: true

require 'test_helper'

# Both mailers, rendered for real. A missing template is invisible to every
# static check in this suite and only shows up when someone tries to sign in —
# which is how the notice mailer once shipped broken.
if RAILS_LOADED
  class MailersTest < ActionMailer::TestCase
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_from = Bible270.config.mailer_from
      Bible270.config.mailer_from = 'no-reply@example.org'
    end

    def teardown
      Bible270.config.mailer_from = @previous_from
      Bible270.config.mailer_reply_to = nil if reply_to_supported?
    end

    def reply_to_supported?
      Bible270.config.respond_to?(:mailer_reply_to=)
    end

    # A mailer with both a text and an HTML template is multipart, and the
    # top-level body is only the MIME container — the content is in the parts.
    def body_of(mail)
      return mail.body.to_s unless mail.multipart?

      mail.all_parts.map { |part| part.body.to_s }.join("\n")
    end

    def magic_link
      Bible270::SignInMailer.magic_link(
        email: 'reader@example.org', url: 'https://example.org/link', expires_in_minutes: 20
      )
    end

    def test_the_sign_in_email_renders_both_parts
      mail = magic_link

      assert_equal ['reader@example.org'], mail.to
      assert_equal ['no-reply@example.org'], mail.from
      assert_match(%r{sign-in}i, mail.subject)

      assert mail.multipart?, 'should offer a text and an HTML part'
      assert_match(%r{https://example\.org/link}, mail.text_part.body.to_s)
      assert_match(%r{https://example\.org/link}, mail.html_part.body.to_s)
      assert_match(%r{20}, body_of(mail), 'should say how long the link lasts')
    end

    def test_the_sign_in_email_is_not_wrapped_in_a_host_layout
      # `layout nil` would nest our complete document inside the host's mailer
      # layout, giving two <html> elements.
      html = magic_link.html_part.body.to_s

      assert_operator html.scan(%r{<html}i).size, :<=, 1
    end

    def test_reply_to_is_only_set_when_configured
      skip 'config.mailer_reply_to not present' unless reply_to_supported?

      assert_nil magic_link.reply_to

      Bible270.config.mailer_reply_to = 'admin@example.org'
      assert_equal ['admin@example.org'], magic_link.reply_to
    end

    def test_the_registration_notice_renders
      skip 'notice mailer not present' unless defined?(Bible270::NoticeMailer)

      reader = Bible270::Reader.create!(provider: 'email', uid: 'new@example.org',
                                        email: 'new@example.org', display_name: 'New Reader')
      mail = Bible270::NoticeMailer.new_reader(reader_id: reader.id,
                                               recipients: ['admin@example.org'])

      assert_equal ['admin@example.org'], mail.to
      assert_match(%r{New Reader}, mail.subject)

      body = body_of(mail)
      assert_match(%r{New Reader}, body)
      assert_match(%r{new@example\.org}, body)
    end

    def test_the_notice_is_not_sent_when_nobody_is_listed
      skip 'notice mailer not present' unless defined?(Bible270::NoticeMailer)

      reader = Bible270::Reader.create!(provider: 'email', uid: 'x@example.org',
                                        email: 'x@example.org', display_name: 'X')
      mail = Bible270::NoticeMailer.new_reader(reader_id: reader.id, recipients: [])

      assert_empty Array(mail.to)
    end
  end
end
