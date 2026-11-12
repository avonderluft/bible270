# frozen_string_literal: true

require_relative 'support/admin_controller_test_case'

if RAILS_LOADED
  class AdminProgressRemovalTest < Bible270AdminControllerTestCase
    def test_an_admin_can_set_progress_exactly
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/through", params: { day: 3 }

      assert_equal 3, @reader.reload.days_completed
    end

    def test_complete_through_rejects_missing_blank_malformed_and_out_of_range_days_without_changing_progress
      @reader.mark_through!(3)
      sign_in_as_admin

      [{}, { day: nil }, { day: '' }, { day: '42oops' }, { day: -1 }, { day: 271 }].each do |params|
        patch "#{mount}/admin/readers/#{@reader.id}/through", params: params

        assert_response :redirect
        assert_equal 3, @reader.reload.days_completed, "changed progress for #{params.inspect}"
        assert_match(%r{between 0 and 270}, flash[:alert].to_s)
      end
    end

    def test_complete_through_accepts_an_explicit_zero_to_clear_progress
      @reader.mark_through!(3)
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/through", params: { day: '0' }

      assert_response :redirect
      assert_equal 0, @reader.reload.days_completed
      assert_match(%r{cleared}, flash[:notice].to_s)
    end

    def test_an_admin_can_toggle_a_single_day
      sign_in_as_admin
      post "#{mount}/admin/readers/#{@reader.id}/days/5"

      assert @reader.reload.day_complete?(5)

      post "#{mount}/admin/readers/#{@reader.id}/days/5"
      assert_equal 0, @reader.reload.checkoffs.where(day: 5).count
    end

    def test_toggle_day_rejects_malformed_and_out_of_range_days_without_changing_progress
      @reader.mark_day_complete!(5)
      original_checkoffs = @reader.checkoffs.order(:day, :track, :part).pluck(:day, :track, :part)
      sign_in_as_admin

      %w[0 42oops 271].each do |day|
        post "#{mount}/admin/readers/#{@reader.id}/days/#{day}"

        assert_response :redirect
        assert_equal original_checkoffs, @reader.reload.checkoffs.order(:day, :track, :part).pluck(:day, :track, :part)
        assert_match(%r{outside the plan}, flash[:alert].to_s)
      end
    end

    def test_an_admin_can_move_a_reader_to_a_day
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/start", params: { day: 42 }

      refute_nil @reader.reload.started_on
      # Bible270.today, not Date.current: the latter is UTC unless the host sets a
      # zone, so on a machine behind UTC this asserted a day too far ahead.
      assert_equal 42, Bible270::Plan.day_for(Bible270.today, @reader.started_on)
    end

    def test_moving_a_reader_rejects_malformed_and_out_of_range_days_without_changing_the_date
      @reader.set_start_date!('2026-07-01')
      original_date = @reader.started_on
      sign_in_as_admin

      %w[0 42oops 271].each do |day|
        patch "#{mount}/admin/readers/#{@reader.id}/start", params: { day: day }

        assert_response :redirect
        assert_equal original_date, @reader.reload.started_on, "changed start date for #{day.inspect}"
        assert_match(%r{between 1 and 270}, flash[:alert].to_s)
      end
    end

    def test_an_invalid_reader_start_date_preserves_the_existing_date
      @reader.set_start_date!('2026-07-01')
      original_date = @reader.started_on
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/start", params: { start_date: 'not a date' }

      assert_response :redirect
      assert_equal original_date, @reader.reload.started_on
      assert_match(%r{Couldn't read}, flash[:alert].to_s)
    end

    # Personal calendars may be disabled while an administrator prepares a date
    # that will take effect if they are enabled later.
    def test_an_admin_can_set_a_date_when_personal_calendars_are_disabled
      previous = Bible270.config.allow_reader_start_date
      Bible270.config.allow_reader_start_date = false
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/start", params: { start_date: '2026-09-06' }

      assert_equal Date.new(2026, 9, 6), @reader.reload.started_on
    ensure
      Bible270.config.allow_reader_start_date = previous
    end

    def test_reader_removal_form_requires_explicit_confirmation
      @reader.update!(display_name: 'R "Reader" <example>')
      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"

      assert_response :success
      assert_select 'form[data-b270-remove-reader]', count: 1 do |forms|
        form = forms.first
        assert_equal "#{mount}/admin/readers/#{@reader.id}", form['action']
        assert_equal 'post', form['method']
        assert_equal "Are you sure you want to remove #{@reader.display_name} from the plan? All their check-offs and reflections will be permanently deleted. This cannot be undone.", form['data-b270-remove-reader']
        assert_nil form['data-turbo-confirm'], 'avoid a second Turbo confirmation'
        assert_select 'input[name="_method"][value="delete"]'
        assert_select 'button[type="submit"]', text: "Remove #{@reader.display_name}"
      end
      assert_select 'script[data-b270-reader-removal]', count: 1
      assert Bible270::Reader.exists?(@reader.id)
    end

    def test_an_admin_can_remove_a_reader
      sign_in_as_admin
      id = @reader.id
      delete "#{mount}/admin/readers/#{id}"

      refute Bible270::Reader.exists?(id)
    end

    def test_removing_a_reader_takes_their_reflections_with_them
      @reader.comments.create!(day: 1, body: 'Something')
      sign_in_as_admin

      delete "#{mount}/admin/readers/#{@reader.id}"

      assert_equal 0, Bible270::Comment.count
    end

    def test_removing_a_reader_cascades_checkoffs_threads_replies_likes_and_avatar_attachment
      @reader.mark_day_complete!(1)
      readers_root = @reader.comments.create!(day: 1, body: 'Reader root')
      reply_to_reader = @admin.comments.create!(day: 1, body: 'Admin reply', parent: readers_root)
      admins_root = @admin.comments.create!(day: 2, body: 'Admin root')
      readers_reply = @reader.comments.create!(day: 2, body: 'Reader reply', parent: admins_root)
      readers_root.toggle_like!(@admin)
      admins_root.toggle_like!(@reader)
      attachment_id = nil
      if Bible270::Reader.avatar_uploads?
        @reader.avatar.attach(io: StringIO.new('avatar'), filename: 'avatar.png', content_type: 'image/png')
        attachment_id = @reader.avatar_attachment.id
      end
      sign_in_as_admin

      perform_enqueued_jobs do
        delete "#{mount}/admin/readers/#{@reader.id}"
      end

      refute Bible270::Reader.exists?(@reader.id)
      assert_equal 0, Bible270::Checkoff.where(reader_id: @reader.id).count
      refute Bible270::Comment.exists?(readers_root.id)
      refute Bible270::Comment.exists?(reply_to_reader.id), 'replies to the deleted root should also go'
      refute Bible270::Comment.exists?(readers_reply.id)
      assert Bible270::Comment.exists?(admins_root.id), 'another reader’s root should remain'
      assert_equal 0, Bible270::Like.where(reader_id: @reader.id).count
      assert_equal 0, Bible270::Like.where(comment_id: readers_root.id).count
      refute ActiveStorage::Attachment.exists?(attachment_id) if attachment_id
    end

    def test_an_ordinary_reader_cannot_delete_another_reader
      sign_in_as(@reader)
      reader_count = Bible270::Reader.count

      delete "#{mount}/admin/readers/#{@admin.id}"

      assert_response :not_found
      assert_equal reader_count, Bible270::Reader.count
      assert Bible270::Reader.exists?(@admin.id)
    end
  end
end
