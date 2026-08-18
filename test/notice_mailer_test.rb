# frozen_string_literal: true

require 'test_helper'

# The two notices to whoever runs the plan. Both guard against a record that has
# gone away, and both link back only when config.mailer_host is set — a mailer has
# no request to derive a host from, and a broken link is worse than none.
if RAILS_LOADED
  class NoticeMailerTest < ActionMailer::TestCase
    def setup
      needs_rails!
      clear_engine_tables!
      @previous = { from: Bible270.config.mailer_from, host: Bible270.config.mailer_host }
      Bible270.config.mailer_from = 'no-reply@example.org'
      Bible270.config.mailer_host = nil

      @andrew = Bible270::Reader.create!(provider: 'email', uid: 'a@example.org', email: 'a@example.org',
                                         display_name: 'Andrew vonderLuft',
                                         first_name: 'Andrew', last_name: 'vonderLuft')
      @mary = Bible270::Reader.create!(provider: 'email', uid: 'm@example.org', email: 'm@example.org',
                                       display_name: 'Mary Smith', first_name: 'Mary', last_name: 'Smith')
    end

    def teardown
      Bible270.config.mailer_from = @previous[:from]
      Bible270.config.mailer_host = @previous[:host]
    end

    # Both mailers are multipart, so the content is in the parts rather than the
    # top-level body.
    def body_of(mail)
      return mail.body.to_s unless mail.multipart?

      mail.all_parts.map { |part| part.body.to_s }.join("\n")
    end

    def notice = Bible270::NoticeMailer.new_reader(reader_id: @mary.id, recipients: ['boss@example.org'])

    # ---- a new reader ------------------------------------------------------

    def test_the_registration_notice_names_the_reader_and_the_running_total
      mail = notice

      assert_equal ['boss@example.org'], mail.to
      assert_equal ['no-reply@example.org'], mail.from
      assert_match(%r{Mary Smith}, mail.subject)

      body = body_of(mail)
      assert_match(%r{Mary Smith}, body)
      assert_match(%r{m@example\.org}, body)
      assert_match(%r{2 readers}, body, 'should say how many are taking part')
    end

    def test_it_reports_the_sign_in_method
      omniauth = Bible270::Reader.create!(provider: 'github', uid: '99', email: 'g@example.org',
                                          display_name: 'Git Hubbard')
      mail = Bible270::NoticeMailer.new_reader(reader_id: omniauth.id, recipients: ['boss@example.org'])

      assert_match(%r{github}i, body_of(mail))
    end

    def test_a_reader_with_no_email_is_described_rather_than_left_blank
      bridged = Bible270::Reader.create!(provider: 'owner', uid: 'host-7', display_name: 'Host User')
      mail = Bible270::NoticeMailer.new_reader(reader_id: bridged.id, recipients: ['boss@example.org'])

      assert_match(%r{none given}i, body_of(mail))
    end

    def test_no_notice_for_a_reader_that_has_gone
      mail = Bible270::NoticeMailer.new_reader(reader_id: 999_999, recipients: ['boss@example.org'])

      refute mail.perform_deliveries
    end

    def test_no_notice_when_nobody_is_listed
      [[], nil, [''], ['   '], [nil]].each do |recipients|
        mail = Bible270::NoticeMailer.new_reader(reader_id: @mary.id, recipients: recipients)
        refute mail.perform_deliveries, "#{recipients.inspect} should send nothing"
      end
    end

    def test_blank_addresses_are_dropped_from_a_mixed_list
      mail = Bible270::NoticeMailer.new_reader(reader_id: @mary.id,
                                               recipients: ['boss@example.org', '', nil, ' '])

      assert_equal ['boss@example.org'], mail.to
    end

    def test_it_links_to_the_admin_page_only_when_a_host_is_configured
      refute_match(%r{https?://}, body_of(notice), 'no host, no link')

      Bible270.config.mailer_host = 'gknt.org'
      body = body_of(notice)
      assert_match(%r{https://gknt\.org}, body)
      assert_match(%r{/admin/readers/#{@mary.id}}, body)
    end

    # Local testing would otherwise produce https://localhost:3336, which no
    # browser will open.
    def test_a_local_host_uses_http
      Bible270.config.mailer_host = 'localhost:3336'

      assert_match(%r{http://localhost:3336}, body_of(notice))
    end

    def test_an_unusable_host_leaves_the_link_out_rather_than_raising
      Bible270.config.mailer_host = 'not a host at all'

      body_of(notice) # must not raise
      assert true
    end

    # The engine resolves its own mount prefix from routes.rb, so the link carries
    # it without help. An earlier version of this passed script_name from
    # config.mount_at, which was ignored when blank and wrong when it disagreed
    # with the real mount.
    def test_the_link_carries_the_mount_prefix_from_the_real_mount
      Bible270.config.mailer_host = 'gknt.org'
      mount = Bible270.config.mount_at.chomp('/')

      assert_match(%r{https://gknt\.org#{Regexp.escape(mount)}/admin/readers/#{@mary.id}},
                   body_of(notice))
    end

    def test_the_link_never_doubles_a_slash
      Bible270.config.mailer_host = 'gknt.org'

      refute_match(%r{gknt\.org//}, body_of(notice))
    end

    # ---- a mention --------------------------------------------------------

    def mention_notice(comment)
      Bible270::NoticeMailer.mentioned(comment_id: comment.id, reader_id: @andrew.id)
    end

    def test_the_mention_notice_quotes_the_reflection
      comment = @mary.comments.create!(day: 7, body: 'Good point @andrew about Genesis')
      mail = mention_notice(comment)

      assert_equal [@andrew.email], mail.to
      assert_match(%r{Mary Smith}, mail.subject)
      assert_match(%r{day 7}, mail.subject)
      assert_match(%r{Good point}, body_of(mail))
    end

    def test_the_mention_notice_explains_why_it_was_sent
      comment = @mary.comments.create!(day: 1, body: 'Hello @andrew')
      body = body_of(mention_notice(comment))

      assert_match(%r{someone wrote your name in a reflection}i, body)
      refute_match(%r{profile}i, body)
    end

    def test_the_mention_notice_links_to_the_day_when_a_host_is_set
      comment = @mary.comments.create!(day: 7, body: 'Hello @andrew')

      refute_match(%r{https?://}, body_of(mention_notice(comment)))

      Bible270.config.mailer_host = 'gknt.org'
      assert_match(%r{https://gknt\.org.*day/7}, body_of(mention_notice(comment)))
    end

    def test_the_mention_link_carries_the_mount_prefix
      Bible270.config.mailer_host = 'gknt.org'
      mount = Bible270.config.mount_at.chomp('/')
      comment = @mary.comments.create!(day: 7, body: 'Hello @andrew')

      assert_match(%r{https://gknt\.org#{Regexp.escape(mount)}/day/7},
                   body_of(mention_notice(comment)))
    end

    def test_no_mention_notice_when_the_reflection_has_gone
      mail = Bible270::NoticeMailer.mentioned(comment_id: 999_999, reader_id: @andrew.id)

      refute mail.perform_deliveries
    end

    def test_no_mention_notice_when_the_reader_has_gone
      comment = @mary.comments.create!(day: 1, body: 'Hello @andrew')
      mail = Bible270::NoticeMailer.mentioned(comment_id: comment.id, reader_id: 999_999)

      refute mail.perform_deliveries
    end

    # A bridged host user may have no address; there is nowhere to send it.
    def test_no_mention_notice_to_a_reader_without_an_email
      bridged = Bible270::Reader.create!(provider: 'owner', uid: 'host-8', display_name: 'No Email')
      comment = @mary.comments.create!(day: 1, body: 'Hello @noemail')
      mail = Bible270::NoticeMailer.mentioned(comment_id: comment.id, reader_id: bridged.id)

      refute mail.perform_deliveries
    end

    def test_a_reply_notice_reads_the_same_way
      thought = @andrew.comments.create!(day: 3, body: 'My reflection')
      reply = @mary.comments.create!(day: 3, body: '@andrew quite so', parent: thought)

      mail = mention_notice(reply)

      assert_equal [@andrew.email], mail.to
      assert_match(%r{quite so}, body_of(mail))
    end
  end
end
