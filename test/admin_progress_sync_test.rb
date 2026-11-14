# frozen_string_literal: true

require 'test_helper'
require 'bible270/progress_sync'

if RAILS_LOADED
  class AdminProgressSyncTest < ActionDispatch::IntegrationTest
    self.use_transactional_tests = false

    Sync = Bible270::ProgressSync
    Controller = Bible270::AdminProgressSyncsController

    def run
      config = Bible270.config.dup
      %i[progress_sync_instance_id progress_sync_destinations progress_sync_sources].each do |field|
        config.singleton_class.attr_accessor(field) unless config.respond_to?(field)
      end
      config.progress_sync_instance_id = 'source-instance'
      config.progress_sync_destinations = {
        'church' => { label: 'Church readers', url: 'https://church.example/bible', secret: 'private-secret-' * 4 },
        'other' => { 'label' => 'Other readers', 'url' => 'https://other.example/plan', 'secret' => 'other-secret-' * 4 }
      }
      config.progress_sync_sources = {}
      config.admin_emails = []
      config.admin_resolver = nil
      config.mention_notifications = false
      config.registration_notice_emails = []
      Bible270.stub(:config, config) do
        Sync.stub(:deliver_pending, 0) { super }
      end
    end

    def setup
      Bible270::ProgressSyncDelivery.delete_all
      Bible270::ProgressSyncLink.delete_all
      clear_engine_tables!
      @admin = reader('admin', admin: true)
      @reader = reader('reader')
      @other = reader('other')
      @membership = @reader.participation
      @remote = {
        'reader_id' => 22, 'participation_id' => 33, 'generation' => 2,
        'name' => 'Remote Reader <trusted>', 'email' => ' READER@example.org ', 'plan_fingerprint' => Sync.fingerprint
      }
      ActionMailer::Base.deliveries.clear
    end

    def test_visitors_cannot_use_any_sync_action
      assert_actions_denied
    end

    def test_ordinary_readers_cannot_use_any_sync_action
      sign_in(@reader)
      assert_actions_denied
    end

    def test_admin_reader_view_cannot_use_any_sync_action
      sign_in(@admin)
      patch "#{mount}/admin/view", params: { view: 'reader' }
      assert_actions_denied
    end

    def test_normal_admin_finds_then_confirms_authenticated_account_without_destination_login
      refute Bible270.config.site_admin?(@admin)
      sign_in(@admin)
      @reader.update!(email: ' Reader@EXAMPLE.org ')
      token = find_account
      assert_empty Bible270::ProgressSyncLink.all
      follow_redirect!
      assert_response :success
      assert_select '#b270-progress-sync h2', text: 'Progress sync'
      assert_select '#b270-progress-sync .b270-select-wrap select[name="destination"]'
      assert_select '.b270-progress-sync-candidate', text: %r{Remote Reader <trusted>.*READER@example.org.*Confirm this account\. Existing progress is copied only when requested\.}m do |candidates|
        refute_match(%r{membership|generation}i, candidates.first.text)
      end
      assert_select '.b270-progress-sync-candidate input[type="submit"][value="Link account"]'
      assert_select '.b270-progress-sync-candidate script', count: 0
      refute_includes response.body, 'private-secret-'
      refute_includes response.body, 'other-secret-'
      refute_includes response.body, 'https://church.example'

      assert_difference('Bible270::ProgressSyncLink.count', 1) do
        confirm(token, remote_reader_id: 999, remote_participation_id: 999, email: 'attacker@example.org')
      end
      assert_panel_redirect
      link = Bible270::ProgressSyncLink.last
      assert_equal 22, link.remote_reader_id
      assert_equal 33, link.remote_participation_id
      assert_equal 2, link.remote_generation
      assert_equal 'reader@example.org', link.email
      assert_equal @membership.id, link.participation_id
      assert_empty Bible270::ProgressSyncDelivery.all
      assert_nil request.session[Controller::CANDIDATE_SESSION_KEY]
      assert_empty ActionMailer::Base.deliveries
    end

    def test_forged_or_missing_candidate_is_rejected
      sign_in(@admin)
      token = find_account
      [nil, 'forged', "#{token}tampered"].each { |candidate| assert_confirmation_rejected(candidate) }
    end

    def test_candidate_cannot_be_used_for_another_reader_or_destination
      sign_in(@admin)
      token = find_account
      assert_confirmation_rejected(token, reader: @other)
      assert_confirmation_rejected(token, destination: 'other')
      assert_confirmation_rejected(token, destination: 'https://attacker.example')
    end

    def test_candidate_is_bound_to_the_confirming_admin
      sign_in(@admin)
      token = find_account
      second_admin = reader('second-admin', admin: true)
      sign_in(second_admin)
      assert_confirmation_rejected(token)
    end

    def test_candidate_expires_after_ten_minutes
      sign_in(@admin)
      token = find_account
      travel 11.minutes do
        assert_confirmation_rejected(token)
      end
    end

    def test_candidate_is_invalid_after_local_email_changes
      sign_in(@admin)
      token = find_account
      @reader.update!(email: 'changed@example.org')
      assert_confirmation_rejected(token)
    end

    def test_email_case_and_whitespace_changes_do_not_change_the_account
      sign_in(@admin)
      token = find_account
      @reader.update!(email: ' READER@EXAMPLE.org ')
      assert_difference('Bible270::ProgressSyncLink.count', 1) { confirm(token) }
    end

    def test_candidate_is_invalid_after_source_generation_changes
      sign_in(@admin)
      token = find_account
      @membership.increment!(:progress_sync_generation)
      assert_confirmation_rejected(token)
    end

    def test_candidate_is_invalid_after_source_run_changes
      sign_in(@admin)
      token = find_account
      Bible270::PlanRun.current.update!(current: false)
      run = Bible270::PlanRun.create!(current: true)
      @reader.participations.create!(plan_run: run, joined_at: Time.current, active: true)
      assert_confirmation_rejected(token)
    end

    def test_candidate_is_invalid_when_source_becomes_alumni
      sign_in(@admin)
      token = find_account
      @membership.update!(active: false)
      assert_confirmation_rejected(token)
    end

    def test_candidate_is_invalid_after_destination_url_or_instance_changes
      sign_in(@admin)
      token = find_account
      Bible270.config.progress_sync_destinations['church'][:url] = 'https://replacement.example/bible'
      assert_confirmation_rejected(token)
      token = find_account
      Bible270.config.progress_sync_instance_id = 'replacement-instance'
      assert_confirmation_rejected(token)
    end

    def test_lookup_rejects_a_remote_email_mismatch
      sign_in(@admin)
      Sync.stub(:lookup, @remote.merge('email' => 'someone-else@example.org')) do
        post "#{sync_path}/lookup", params: { destination: 'church' }
      end
      assert_panel_redirect
      assert_match(%r{email does not match}, flash[:alert])
      assert_nil request.session[Controller::CANDIDATE_SESSION_KEY]
      assert_empty Bible270::ProgressSyncLink.all
    end

    def test_confirm_rechecks_the_signed_remote_email
      sign_in(@admin)
      token = find_account
      payload = Controller.verifier.verified(token, purpose: Controller::CANDIDATE_PURPOSE)
      payload['remote']['email'] = 'someone-else@example.org'
      token = Controller.verifier.generate(payload, expires_in: 10.minutes, purpose: Controller::CANDIDATE_PURPOSE)
      assert_confirmation_rejected(token)
    end

    def test_lookup_checks_local_membership_email_and_allowlist_before_network
      sign_in(@admin)
      Sync.stub(:lookup, ->(**) { flunk 'Invalid local lookup must not contact the destination' }) do
        @membership.update!(active: false)
        post "#{sync_path}/lookup", params: { destination: 'church' }
        assert_panel_redirect
        @membership.update!(active: true)
        @reader.update!(email: nil)
        post "#{sync_path}/lookup", params: { destination: 'church' }
        assert_panel_redirect
        @reader.update!(email: 'reader@example.org')
        post "#{sync_path}/lookup", params: { destination: 'https://attacker.example' }
        assert_panel_redirect
      end
      assert_empty Bible270::ProgressSyncLink.all
    end

    def test_lookup_errors_clear_old_candidates_and_show_only_safe_core_error
      sign_in(@admin)
      find_account
      Sync.stub(:lookup, ->(**) { raise Sync::Unavailable, 'Progress sync destination could not be reached securely' }) do
        post "#{sync_path}/lookup", params: { destination: 'church' }
      end
      assert_panel_redirect
      assert_equal 'Progress sync destination could not be reached securely', flash[:alert]
      assert_nil request.session[Controller::CANDIDATE_SESSION_KEY]
    end

    def test_duplicate_confirmation_does_not_create_another_active_link
      sign_in(@admin)
      token = find_account
      confirm(token)
      assert_no_difference('Bible270::ProgressSyncLink.count') { confirm(token) }
      assert_panel_redirect
      assert_match(%r{already be linked}, flash[:alert])
    end

    def test_copy_and_unlink_preserve_progress_dates_and_do_not_send_source_emails
      @reader.mark_day_complete!(1)
      link = create_link
      before = progress_snapshot
      sign_in(@admin)
      assert_difference('Bible270::ProgressSyncDelivery.count', 1) do
        post "#{sync_path}/#{link.id}/copy"
      end
      assert_panel_redirect
      assert_equal @reader.checkoffs.order(:day, :track, :part).pluck(:day, :track, :part), link.deliveries.last.readings
      assert_equal before, progress_snapshot
      assert_difference('Bible270::ProgressSyncLink.count', -1) do
        assert_difference('Bible270::ProgressSyncDelivery.count', -1) do
          delete "#{sync_path}/#{link.id}"
        end
      end
      assert_panel_redirect
      assert_equal before, progress_snapshot
      assert_empty ActionMailer::Base.deliveries
    end

    def test_copy_empty_progress_is_a_safe_noop
      sign_in(@admin)
      link = create_link
      assert_no_difference('Bible270::ProgressSyncDelivery.count') { post "#{sync_path}/#{link.id}/copy" }
      assert_panel_redirect
      assert_match(%r{no existing progress}, flash[:notice])
    end

    def test_link_actions_are_scoped_to_the_readers_entire_membership_history
      link = create_link(reader: @other)
      sign_in(@admin)
      before = progress_snapshot
      post "#{sync_path}/#{link.id}/copy"
      assert_response :not_found
      delete "#{sync_path}/#{link.id}"
      assert_response :not_found
      assert Bible270::ProgressSyncLink.exists?(link.id)
      assert_empty link.deliveries
      assert_equal before, progress_snapshot
    end

    def test_panel_lists_history_status_results_and_safe_errors_with_shared_confirmations
      link = create_link
      link.update!(last_synced_at: Time.current, last_added: 4, last_existing: 7)
      link.deliveries.create!(readings: [[1, 'ot', 0]], next_attempt_at: Time.current)
      sign_in(@admin)
      get reader_path
      assert_select '.b270-progress-sync-link', text: %r{Church readers.*Remote Reader <trusted>.*Pending.*Last synced:.*Pending: 1.*4 added; 7 already present}m
      assert_select "#b270-progress-sync form.b270-admin-inline-form[action='#{sync_path}/#{link.id}/copy'][data-b270-admin-confirm]" do |forms|
        assert_match(%r{Only missing check-offs will be added}, forms.first['data-b270-admin-confirm'])
        assert_select 'button[type="submit"]', text: 'Sync existing progress'
      end
      assert_select "#b270-progress-sync form.b270-admin-inline-form[action='#{sync_path}/#{link.id}'][data-b270-admin-confirm]" do |forms|
        assert_match(%r{All check-offs will remain}, forms.first['data-b270-admin-confirm'])
        assert_select 'input[name="_method"][value="delete"]'
        assert_select 'button[type="submit"]', text: 'Unlink'
      end
      assert_select '#b270-progress-sync.b270-admin-control, #b270-progress-sync details, #b270-progress-sync input[type="checkbox"], #b270-progress-sync script', count: 0

      @membership.update!(active: false)
      link.update!(last_error: 'Destination rejected the linked reader <retry>')
      get reader_path
      assert_select '.b270-progress-sync-link', text: %r{Needs attention.*Destination rejected the linked reader <retry>}m
      assert_select '#b270-progress-sync input[value="Find account"], #b270-progress-sync form[action$="/copy"]', count: 0
      assert_select '#b270-progress-sync .b270-hint', text: 'Find and link the account again to resume syncing.'
      assert_select "#b270-progress-sync form[action='#{sync_path}/#{link.id}'][data-b270-admin-confirm] button", text: 'Unlink'
      delete "#{sync_path}/#{link.id}"
      assert_panel_redirect
      refute Bible270::ProgressSyncLink.exists?(link.id)
    end

    def test_unusable_links_need_explicit_find_and_link_not_copy_or_auto_resume
      link = create_link
      @membership.increment!(:progress_sync_generation)
      sign_in(@admin)
      assert_no_difference('Bible270::ProgressSyncDelivery.count') { post "#{sync_path}/#{link.id}/copy" }
      assert_panel_redirect
      assert link.reload.paused?
      token = find_account
      assert_difference('Bible270::ProgressSyncLink.count', 1) { confirm(token) }
      assert link.reload.paused?
      assert Bible270::ProgressSyncLink.last.usable?
    end

    def test_panel_retains_links_from_previous_runs
      link = create_link
      @membership.update!(active: false)
      Bible270::PlanRun.current.update!(current: false)
      run = Bible270::PlanRun.create!(current: true)
      @reader.participations.create!(plan_run: run, joined_at: Time.current, active: true)
      sign_in(@admin)
      get reader_path
      assert_select '.b270-progress-sync-link', text: %r{Run #{link.participation.plan_run_id}}
      assert_select '#b270-progress-sync form[action$="/copy"]', count: 0
      delete "#{sync_path}/#{link.id}"
      assert_panel_redirect
    end

    def test_panel_hides_without_destinations_or_links_but_retains_unlink_when_config_removed
      sign_in(@admin)
      destinations = Bible270.config.progress_sync_destinations
      Bible270.config.progress_sync_destinations = {}
      get reader_path
      assert_select '#b270-progress-sync', count: 0
      Bible270.config.progress_sync_destinations = destinations
      link = create_link
      Bible270.config.progress_sync_destinations = {}
      get reader_path
      assert_select '#b270-progress-sync', count: 1
      assert_select '#b270-progress-sync input[value="Find account"], #b270-progress-sync form[action$="/copy"]', count: 0
      delete "#{sync_path}/#{link.id}"
      assert_panel_redirect
    end

    def test_missing_instance_config_or_schema_is_informative_and_safe
      sign_in(@admin)
      Bible270.config.progress_sync_instance_id = nil
      get reader_path
      assert_select '#b270-progress-sync', text: %r{Ask the site administrator to set up progress sync}
      Sync.stub(:lookup, ->(**) { flunk 'Unconfigured lookup must not contact destination' }) do
        post "#{sync_path}/lookup", params: { destination: 'church' }
      end
      assert_panel_redirect
      Sync.stub(:available?, false) do
        get reader_path
        assert_select '#b270-progress-sync', text: %r{Progress sync needs a site update}
        assert_select '#b270-progress-sync form', count: 0
        post "#{sync_path}/lookup", params: { destination: 'church' }
        assert_panel_redirect
        post sync_path, params: { candidate: 'anything', destination: 'church' }
        assert_panel_redirect
        post "#{sync_path}/1/copy"
        assert_panel_redirect
        delete "#{sync_path}/1"
        assert_panel_redirect
      end
    end

  private

    def reader(name, **attributes)
      Bible270::Reader.create!(provider: 'email', uid: "#{name}@example.org", email: "#{name}@example.org",
                               display_name: name.capitalize, **attributes)
    end

    def mount = Bible270.config.mount_at.chomp('/')
    def reader_path(target = @reader) = "#{mount}/admin/readers/#{target.id}"
    def sync_path(target = @reader) = "#{reader_path(target)}/progress-sync"

    def sign_in(target)
      _record, raw = Bible270::SignInToken.issue!(target.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def find_account
      Sync.stub(:lookup, ->(destination:, email:) {
        refute ActiveRecord::Base.connection.transaction_open?, 'Lookup HTTP must not be in a database transaction'
        assert_equal 'church', destination
        assert_equal 'reader@example.org', email
        @remote
      }) do
        post "#{sync_path}/lookup", params: { destination: 'church', email: 'ignored@example.org' }
      end
      assert_panel_redirect
      token = request.session[Controller::CANDIDATE_SESSION_KEY]
      assert token.present?
      token
    end

    def confirm(token, reader: @reader, destination: 'church', **untrusted)
      post sync_path(reader), params: { candidate: token, destination: destination, **untrusted }
    end

    def assert_confirmation_rejected(token, **options)
      assert_no_difference('Bible270::ProgressSyncLink.count') { confirm(token, **options) }
      assert_panel_redirect(options.fetch(:reader, @reader))
      assert_match(%r{confirmation expired or changed}, flash[:alert])
    end

    def assert_panel_redirect(target = @reader)
      assert_response :see_other
      assert_redirected_to "#{reader_path(target)}#b270-progress-sync"
    end

    def create_link(reader: @reader)
      remote = @remote.merge('email' => reader.email)
      Sync.link!(reader: reader, destination: 'church', remote: remote, expected_participation_id: reader.participation.id)
    end

    def progress_snapshot
      [@reader.reload.attributes, @reader.participations.order(:id).map(&:attributes),
       @reader.all_checkoffs.order(:id).map(&:attributes)]
    end

    def assert_actions_denied
      Sync.stub(:lookup, ->(**) { flunk 'Unauthorized request must not contact destination' }) do
        [[:post, "#{sync_path}/lookup"], [:post, sync_path], [:post, "#{sync_path}/1/copy"], [:delete, "#{sync_path}/1"]].each do |method, path|
          public_send(method, path, params: { destination: 'church' })
          assert_response :not_found
        end
      end
      assert_empty Bible270::ProgressSyncLink.all
      assert_empty Bible270::ProgressSyncDelivery.all
      assert_empty ActionMailer::Base.deliveries
    end
  end
end
