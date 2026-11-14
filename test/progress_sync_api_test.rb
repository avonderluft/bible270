# frozen_string_literal: true

require 'test_helper'
require 'bible270/progress_sync/client'

if RAILS_LOADED
  class ProgressSyncApiTest < ActionDispatch::IntegrationTest
    self.use_transactional_tests = false

    Sync = Bible270::ProgressSync
    Auth = Sync::Authentication

    def run
      config = Bible270.config.dup

      config.progress_sync_instance_id = 'destination-instance'
      config.progress_sync_destinations = {}
      config.progress_sync_sources = { 'source-instance' => { secret: 's' * 32 } }
      config.progress_sync_deliver_later = false
      config.admin_emails = []
      config.admin_resolver = nil
      config.mention_notifications = false
      config.registration_notice_emails = []
      Bible270.stub(:config, config) { super }
    end

    def setup
      Bible270::ProgressSyncDelivery.delete_all
      Bible270::ProgressSyncLink.delete_all
      clear_engine_tables!
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'reader@example.org',
                                         email: 'reader@example.org', display_name: 'Remote Reader')
      @membership = @reader.participation
      @fingerprint = Sync.fingerprint
      @binding = { reader_id: @reader.id, participation_id: @membership.id,
                   generation: @membership.progress_sync_generation, plan_fingerprint: @fingerprint }
    end

    def test_lookup_matches_only_an_existing_active_reader_by_normalized_email
      signed_post('lookup', { email: ' READER@Example.org ', plan_fingerprint: @fingerprint })
      assert_response :ok
      assert_equal({ 'reader_id' => @reader.id, 'participation_id' => @membership.id,
                     'generation' => @membership.progress_sync_generation, 'name' => 'Remote Reader',
                     'email' => 'reader@example.org', 'plan_fingerprint' => @fingerprint }, response.parsed_body)
    end

    def test_stored_email_uses_the_same_normalization_including_alumni_ambiguity
      @reader.update!(email: "\tREADER@Example.org\r\n")
      signed_post('lookup', { email: 'reader@example.org', plan_fingerprint: @fingerprint })
      assert_response :ok
      assert_equal @reader.id, response.parsed_body['reader_id']
      duplicate = Bible270::Reader.create!(provider: 'developer', uid: 'whitespace-duplicate',
                                           email: " reader@example.org\t", display_name: 'Duplicate')
      duplicate.archive!
      signed_post('lookup', { email: 'reader@example.org', plan_fingerprint: @fingerprint })
      assert_response :conflict
    end

    def test_lookup_never_enrolls_creates_or_selects_an_ambiguous_identity
      signed_post('lookup', { email: 'missing@example.org', plan_fingerprint: @fingerprint })
      assert_response :conflict
      assert_equal 1, Bible270::Reader.count
      assert_equal 1, Bible270::Participation.count
      duplicate = Bible270::Reader.create!(provider: 'developer', uid: 'duplicate',
                                           email: ' READER@EXAMPLE.ORG ', display_name: 'Duplicate')
      duplicate.archive!
      signed_post('lookup', { email: 'reader@example.org', plan_fingerprint: @fingerprint })
      assert_response :conflict
      duplicate.destroy!
      @reader.archive!
      signed_post('lookup', { email: 'reader@example.org', plan_fingerprint: @fingerprint })
      assert_response :conflict
    end

    def test_cookie_session_alone_cannot_authenticate
      _record, token = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{token}"
      post "#{mount}/progress-sync/lookup", params: JSON.generate(email: @reader.email, plan_fingerprint: @fingerprint),
                                            headers: { 'Content-Type' => 'application/json' }
      assert_response :unauthorized
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_authentication_precedes_json_parsing
      signed_post('lookup', '{broken JSON', raw: true, sign_body: '{}')
      assert_response :unauthorized
      signed_post('lookup', '{broken JSON', raw: true)
      assert_response :bad_request
    end

    def test_expired_future_timestamps_tampered_body_path_source_and_version_are_rejected
      [-301, 301].each do |offset|
        signed_post('lookup', lookup_payload, timestamp: (Time.now.to_i + offset).to_s)
        assert_response :unauthorized
      end
      signed_post('lookup', lookup_payload, sign_body: '{}')
      assert_response :unauthorized
      signed_post('lookup', lookup_payload, sign_path: '/wrong-mount/progress-sync/lookup')
      assert_response :unauthorized
      signed_post('lookup', lookup_payload, extra_headers: { Auth::SOURCE_HEADER => 'unknown-source' })
      assert_response :unauthorized
      signed_post('lookup', lookup_payload, extra_headers: { Auth::VERSION_HEADER => '2' })
      assert_response :unauthorized
      signed_post('lookup', lookup_payload.merge(source: 'source-instance'), extra_headers: { Auth::SOURCE_HEADER => '' })
      assert_response :unauthorized
    end

    def test_missing_and_malformed_authentication_headers_are_rejected
      [Auth::SOURCE_HEADER, Auth::TIMESTAMP_HEADER, Auth::SIGNATURE_HEADER, Auth::VERSION_HEADER].each do |header|
        signed_post('lookup', lookup_payload, extra_headers: { header => '' })
        assert_response :unauthorized
      end
      ['not-a-time', '-1', '1.5', '9' * 13].each do |timestamp|
        signed_post('lookup', lookup_payload, timestamp: timestamp)
        assert_response :unauthorized
      end
      ['0' * 64, 'g' * 64, 'a' * 63, "source\ninjection"].each do |signature|
        signed_post('lookup', lookup_payload, extra_headers: { Auth::SIGNATURE_HEADER => signature })
        assert_response :unauthorized
      end
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_short_or_removed_source_secret_fails_closed
      Bible270.config.progress_sync_sources['source-instance'][:secret] = 's' * 31
      signed_post('lookup', lookup_payload)
      assert_response :unauthorized
      Bible270.config.progress_sync_sources = {}
      signed_post('lookup', lookup_payload)
      assert_response :unauthorized
    end

    def test_query_string_is_not_used_as_authentication_identity_or_signature_path
      signed_post('lookup', lookup_payload, query: '?source=untrusted')
      assert_response :ok
    end

    def test_duplicate_triples_are_idempotent_and_counts_refer_to_unique_triples
      payload = @binding.merge(readings: [[1, 'nt', 0], [1, 'nt', 0], [1, 'ot', 0]])
      signed_post('complete', payload)
      assert_response :ok
      assert_equal({ 'added' => 2, 'existing' => 0 }, response.parsed_body)
      signed_post('complete', payload)
      assert_response :ok
      assert_equal({ 'added' => 0, 'existing' => 2 }, response.parsed_body)
      signed_post('complete', @binding.merge(readings: [[1, 'nt', 0], [2, 'nt', 0]]))
      assert_response :ok
      assert_equal({ 'added' => 1, 'existing' => 1 }, response.parsed_body)
      assert_equal 3, Bible270::Checkoff.count
    end

    def test_empty_batch_is_valid
      signed_post('complete', @binding.merge(readings: []))
      assert_response :ok
      assert_equal({ 'added' => 0, 'existing' => 0 }, response.parsed_body)
    end

    def test_api_is_independent_of_host_controller_sessions_and_csrf
      assert_equal ActionController::API, Bible270::ProgressSyncController.superclass
      refute Bible270::ProgressSyncController < Bible270::ApplicationController
      signed_post('complete', @binding.merge(readings: [[1, 'nt', 0]]))
      assert_response :ok
      refute response.headers.key?('Set-Cookie')
    end

    def test_invalid_triples_reject_the_entire_batch_without_changing_existing_progress
      existing = add_checkoff(@reader, [1, 'nt', 0])
      invalid = [nil, {}, [1, 'nt'], [1, 'nt', 0, 1], ['1', 'nt', 0], [1.0, 'nt', 0],
                 [true, 'nt', 0], [0, 'nt', 0], [271, 'nt', 0], [1, 'unknown', 0],
                 [1, nil, 0], [1, ['nt'], 0], [1, 'nt', '0'], [1, 'nt', 0.0],
                 [1, 'nt', -1], [1, 'nt', Bible270::Plan.parts_for(1, 'nt').length]]
      invalid.each do |triple|
        signed_post('complete', @binding.merge(readings: [[2, 'nt', 0], triple]))
        assert_response :conflict
        assert_equal [existing.attributes], Bible270::Checkoff.all.map(&:attributes)
      end
    end

    def test_batch_and_body_limits_are_enforced
      [nil, {}, 'readings', Array.new(5001) { [1, 'nt', 0] }].each do |readings|
        signed_post('complete', @binding.merge(readings: readings))
        assert_response :conflict
      end
      signed_post('complete', @binding.merge(readings: Array.new(5000) { [1, 'nt', 0] }))
      assert_response :ok
      assert_equal({ 'added' => 1, 'existing' => 0 }, response.parsed_body)
      signed_post('lookup', lookup_payload.merge(padding: 'x' * Auth::MAX_BYTES))
      assert_response 413
      assert_equal 1, Bible270::Checkoff.count
    end

    def test_exact_payload_byte_limit_and_missing_content_length
      payload = lookup_payload.merge(padding: '')
      payload[:padding] = 'x' * (Auth::MAX_BYTES - JSON.generate(payload).bytesize)
      body = JSON.generate(payload)
      assert_equal Auth::MAX_BYTES, body.bytesize
      signed_post('lookup', body, raw: true)
      assert_response :ok
      signed_post('lookup', "#{body} ", raw: true, extra_headers: { 'CONTENT_LENGTH' => '' })
      assert_response 413
    end

    def test_lookup_is_exact_and_never_recreates_a_missing_membership
      ['read@example.org', 'reader@example.org.extra'].each do |email|
        signed_post('lookup', lookup_payload.merge(email: email))
        assert_response :conflict
      end
      @membership.destroy!
      signed_post('lookup', lookup_payload)
      assert_response :conflict
      assert_equal 1, Bible270::Reader.count
      assert_equal 0, Bible270::Participation.count
    end

    def test_nonobject_json_and_invalid_emails_are_rejected
      ['null', '[]', 'true', '123'].each do |body|
        signed_post('lookup', body, raw: true)
        assert_response :conflict
      end
      [nil, 123, '', 'reader', 'reader@ example.org', 'x' * 321].each do |email|
        signed_post('lookup', lookup_payload.merge(email: email))
        assert_response :conflict
      end
    end

    def test_plan_fingerprint_is_required_for_lookup_and_completion
      [nil, 'wrong-plan', 123].each do |fingerprint|
        signed_post('lookup', lookup_payload.merge(plan_fingerprint: fingerprint))
        assert_response :conflict
        signed_post('complete', @binding.merge(plan_fingerprint: fingerprint, readings: [[1, 'nt', 0]]))
        assert_response :conflict
      end
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_pinned_identity_survives_email_change_and_never_rematches_the_old_email
      @reader.update!(email: 'changed@example.org')
      other = Bible270::Reader.create!(provider: 'developer', uid: 'new-owner', email: 'reader@example.org', display_name: 'New Owner')
      signed_post('complete', @binding.merge(email: other.email, readings: [[1, 'nt', 0]]))
      assert_response :ok
      assert_equal [[1, 'nt', 0]], @membership.checkoffs.pluck(:day, :track, :part)
      assert_empty other.participation.checkoffs
    end

    def test_foreign_missing_and_badly_typed_identity_bindings_are_rejected
      other = Bible270::Reader.create!(provider: 'developer', uid: 'other', email: 'other@example.org', display_name: 'Other')
      changes = [{ reader_id: other.id }, { participation_id: other.participation.id },
                 { reader_id: 0 }, { reader_id: @reader.id.to_s }, { participation_id: nil },
                 { participation_id: 0 }, { generation: -1 }, { generation: '0' }, { generation: 0.0 },
                 { generation: @binding[:generation] + 1 }, { participation_id: Bible270::Participation.maximum(:id) + 1 }]
      changes.each do |change|
        signed_post('complete', @binding.merge(change).merge(readings: [[1, 'nt', 0]]))
        assert_response :conflict
      end
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_alumni_cannot_receive_completions_and_reactivation_requires_a_new_generation
      @reader.archive!
      assert_operator @membership.reload.progress_sync_generation, :>, @binding[:generation]
      signed_post('complete', @binding.merge(readings: [[1, 'nt', 0]]))
      assert_response :conflict
      @reader.activate!
      assert @membership.reload.active?
      signed_post('complete', @binding.merge(readings: [[1, 'nt', 0]]))
      assert_response :conflict
      assert_equal 0, Bible270::Checkoff.count
      signed_post('lookup', lookup_payload)
      assert_response :ok
      assert_equal @membership.progress_sync_generation, response.parsed_body['generation']
    end

    def test_restart_then_revert_does_not_restore_old_link_generation
      run = Bible270::PlanRun.restart!(start_date: Date.current, expected_run_id: @membership.plan_run_id)
      signed_post('complete', @binding.merge(readings: [[1, 'nt', 0]]))
      assert_response :conflict
      @reader.activate!
      signed_post('lookup', lookup_payload)
      assert_response :ok
      restarted_binding = response.parsed_body.slice('reader_id', 'participation_id', 'generation', 'plan_fingerprint')
      Bible270::PlanRun.revert!(expected_run_id: run.id)
      assert @membership.reload.active?
      assert_operator @membership.progress_sync_generation, :>, @binding[:generation]
      [@binding, restarted_binding].each do |binding|
        signed_post('complete', binding.merge(readings: [[1, 'nt', 0]]))
        assert_response :conflict
      end
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_import_is_add_only_and_does_not_change_dates_membership_or_enrollment
      @reader.update!(started_on: Date.current - 10)
      Bible270::Setting.close_enrollment!
      before = persistent_state
      existing = add_checkoff(@reader, [1, 'ot', 0])
      signed_post('complete', @binding.merge(readings: [[1, 'nt', 0]], started_on: '2000-01-01', active: false))
      assert_response :ok
      assert_equal before, persistent_state
      assert_equal existing.attributes, existing.reload.attributes
      assert_equal [[1, 'nt', 0], [1, 'ot', 0]], @membership.checkoffs.order(:track).pluck(:day, :track, :part)
    end

    def test_database_failure_rolls_back_every_imported_completion
      insert = Bible270::Checkoff.method(:insert_all)
      Bible270::Checkoff.stub(:insert_all, ->(rows) {
        insert.call(rows)
        raise ActiveRecord::RecordInvalid, Bible270::Checkoff.new
      }) do
        signed_post('complete', @binding.merge(readings: [[1, 'nt', 0], [2, 'nt', 0]]))
        assert_response :conflict
      end
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_import_is_suppressed_and_never_fans_out_to_a_configured_local_link
      configure_destination
      link = create_link(@reader, remote_identity)
      insert = Bible270::Checkoff.method(:insert_all)
      Bible270::Checkoff.stub(:insert_all, ->(rows) {
        assert Sync.suppressed?
        insert.call(rows)
      }) do
        signed_post('complete', @binding.merge(readings: [[1, 'nt', 0], [2, 'nt', 0]]))
        assert_response :ok
      end
      refute Sync.suppressed?
      assert_empty link.deliveries
      add_checkoff(@reader, [3, 'nt', 0])
      assert_equal 1, link.deliveries.count, 'the configured local capture hook must actually be enabled'
    end

    def test_missing_migration_is_safe_and_not_disclosed_to_unauthenticated_requests
      Sync.stub(:available?, false) do
        signed_post('lookup', lookup_payload, sign_body: '{}')
        assert_response :unauthorized
        signed_post('lookup', lookup_payload)
        assert_response :service_unavailable
        assert_equal({ 'error' => 'Progress sync is unavailable' }, response.parsed_body)
        signed_post('complete', @binding.merge(readings: [[1, 'nt', 0]]))
        assert_response :service_unavailable
      end
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_real_client_signatures_lookup_outbox_and_remote_import_work_together
      configure_destination
      Bible270.config.progress_sync_instance_id = 'source-instance'
      source = Bible270::Reader.create!(provider: 'email', uid: 'source@example.org', email: 'source@example.org', display_name: 'Source')
      forwarding_link = create_link(@reader, remote_identity)
      with_in_process_http do
        remote = Sync.lookup(destination: 'church', email: ' READER@EXAMPLE.ORG ')
        link = create_link(source, remote)
        add_checkoff(source, [1, 'nt', 0])
        delivery = link.deliveries.sole
        assert_equal 1, Sync.deliver_pending(delivery_id: delivery.id)
        assert delivery.reload.delivered_at
        assert_equal [1, 0], [link.reload.last_added, link.last_existing]
        assert_equal [[1, 'nt', 0]], @membership.checkoffs.pluck(:day, :track, :part)
        assert_empty forwarding_link.deliveries
        assert_equal({ 'added' => 0, 'existing' => 1 }, Sync::Client.new('church').complete(link, delivery.readings))
      end
      assert_equal 2, Bible270::Checkoff.count
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')
    def lookup_payload = { email: @reader.email, plan_fingerprint: @fingerprint }

    def signed_post(action, payload, raw: false, sign_body: nil, sign_path: nil, timestamp: Time.now.to_i.to_s, query: '', extra_headers: {}) # rubocop:disable Metrics/ParameterLists
      body = raw ? payload : JSON.generate(payload)
      path = "#{mount}/progress-sync/#{action}"
      headers = Auth.headers(secret: 's' * 32, source: 'source-instance', method: 'POST',
                             path: sign_path || path, body: sign_body || body, timestamp: timestamp)
      post "#{path}#{query}", params: body, headers: headers.merge('Content-Type' => 'application/json').merge(extra_headers)
    end

    def add_checkoff(reader, triple)
      day, track, part = triple
      Bible270::Checkoff.create!(reader: reader, participation: reader.participation, day: day, track: track, part: part)
    end

    def persistent_state
      [Bible270::Reader.order(:id).map(&:attributes), Bible270::Participation.order(:id).map(&:attributes),
       Bible270::PlanRun.order(:id).map(&:attributes), Bible270::Setting.order(:id).map(&:attributes)]
    end

    def configure_destination
      Bible270.config.progress_sync_destinations = { 'church' => { url: "https://church.example#{mount}", secret: 's' * 32 } }
    end

    def remote_identity
      { 'reader_id' => 123, 'participation_id' => 456, 'generation' => 0, 'name' => 'Elsewhere',
        'email' => 'elsewhere@example.org', 'plan_fingerprint' => @fingerprint }
    end

    def create_link(reader, remote)
      Sync.link!(reader: reader, destination: 'church', remote: remote, expected_participation_id: reader.participation.id)
    end

    # Only the socket is replaced: use the actual client, headers, mounted Rails
    # route, controller, database import, and outbox delivery lifecycle.
    def with_in_process_http(&block)
      integration = self
      http_class = Class.new do
        attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries

        define_method(:start) { |&block| block.call(self) }
        define_method(:request) do |request, &block|
          integration.post request.path, params: request.body, headers: request.each_header.to_h
          result = integration.response
          response = Object.new
          response.define_singleton_method(:code) { result.status.to_s }
          response.define_singleton_method(:[]) { |key| result.headers[key] }
          response.define_singleton_method(:read_body) { |&read| read.call(result.body) }
          block.call(response)
        end
      end
      Net::HTTP.stub(:new, ->(*) { http_class.new }, &block)
    end
  end
end
