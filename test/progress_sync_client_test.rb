# frozen_string_literal: true

require 'test_helper'
require 'bible270/progress_sync/client'

class ProgressSyncClientTest < Minitest::Test
  Sync = Bible270::ProgressSync
  Auth = Sync::Authentication
  Link = Struct.new(:destination_url, :remote_reader_id, :remote_participation_id, :remote_generation, :plan_fingerprint)

  class Response
    attr_reader :code

    def initialize(code, chunks, length = nil)
      @code = code.to_s
      @chunks = Array(chunks)
      @length = length
    end

    def [](key) = key == 'Content-Length' ? @length : nil
    def read_body(&) = @chunks.each(&)
  end

  class HTTP
    attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :request_sent

    def initialize(response)
      @response = response
    end

    def start
      yield self
    end

    def request(request)
      @request_sent = request
      yield @response
    end
  end

  def run
    config = Bible270.config.dup

    config.progress_sync_instance_id = 'source-instance'
    config.progress_sync_destinations = { 'church' => { url: 'https://church.example/bible/', secret: 's' * 32 } }
    Bible270.stub(:config, config) { super }
  end

  def setup
    @digest = Sync.fingerprint
    @remote = { 'reader_id' => 12, 'participation_id' => 34, 'generation' => 0,
                'name' => 'Remote Reader', 'email' => 'reader@example.org', 'plan_fingerprint' => @digest }
    @link = Link.new('https://church.example/bible', 12, 34, 0, @digest)
  end

  def test_https_configuration_timeouts_proxy_and_signature
    with_response(@remote) do |http, arguments|
      result = client.lookup(' Reader@Example.org ')
      assert_equal @remote, result
      assert_equal ['church.example', 443, nil], arguments
      assert http.use_ssl
      assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
      assert_equal [5, 10, 10, 0], [http.open_timeout, http.read_timeout, http.write_timeout, http.max_retries]
      request = http.request_sent
      assert_equal '/bible/progress-sync/lookup', request.path
      assert_equal 'POST', request.method
      assert_equal 'identity', request['Accept-Encoding']
      assert_equal 'application/json', request['Content-Type']
      assert_equal({ 'email' => 'reader@example.org', 'plan_fingerprint' => @digest }, JSON.parse(request.body))
      message = ['1', 'source-instance', request[Auth::TIMESTAMP_HEADER], 'POST', request.path,
                 Digest::SHA256.hexdigest(request.body)].join("\n")
      expected = OpenSSL::HMAC.hexdigest('SHA256', 's' * 32, message)
      assert_equal expected, request[Auth::SIGNATURE_HEADER]
      assert_equal '1', request[Auth::VERSION_HEADER]
    end
  end

  def test_complete_uses_only_pinned_ids_generation_and_plan_not_email
    with_response({ 'added' => 1, 'existing' => 0 }) do |http, _|
      assert_equal({ 'added' => 1, 'existing' => 0 }, client.complete(@link, [[1, 'nt', 0], [1, 'nt', 0]]))
      payload = JSON.parse(http.request_sent.body)
      assert_equal [12, 34, 0, @digest], payload.values_at('reader_id', 'participation_id', 'generation', 'plan_fingerprint')
      refute payload.key?('email')
      assert_equal '/bible/progress-sync/complete', http.request_sent.path
    end
  end

  def test_retargeted_link_is_rejected_without_network
    @link.destination_url = 'https://other.example/bible'
    Net::HTTP.stub(:new, ->(*) { flunk 'must not contact a retargeted destination' }) do
      assert_raises(Sync::ConfigurationError) { client.complete(@link, []) }
    end
  end

  def test_invalid_urls_and_short_secrets_are_rejected_without_network
    ['http://church.example/bible', 'https://user:pass@church.example/bible', 'https://church.example/bible?q=x',
     'https://church.example/bible#fragment', 'https://', 'not a url'].each do |url|
      Bible270.config.progress_sync_destinations['church'][:url] = url
      assert_raises(Sync::ConfigurationError) { client }
    end
    Bible270.config.progress_sync_destinations['church'] = { url: 'https://church.example', secret: 's' * 31 }
    assert_raises(Sync::ConfigurationError) { client }
    assert_raises(Sync::ConfigurationError) { Sync::Client.new('unknown') }
  end

  def test_invalid_source_ids_are_configuration_errors
    [nil, '', "source\ninjected", 'x' * 129].each do |source|
      Bible270.config.progress_sync_instance_id = source
      assert_raises(Sync::ConfigurationError) { client }
    end
  end

  def test_redirects_are_never_followed_and_errors_do_not_include_remote_html
    [301, 302, 307, 308].each do |status|
      with_response('<secret remote HTML>', status: status, raw: true) do
        error = assert_raises(Sync::ConfigurationError) { client.lookup('reader@example.org') }
        refute_includes error.message, 'secret'
      end
    end
  end

  def test_authentication_conflict_and_retryable_status_mapping
    { 401 => Sync::Unauthorized, 403 => Sync::Unauthorized, 409 => Sync::Conflict, 422 => Sync::Conflict,
      404 => Sync::Conflict, 429 => Sync::Unavailable, 500 => Sync::Unavailable, 503 => Sync::Unavailable }.each do |status, error_class|
      with_response('<remote secret>', status: status, raw: true) do
        error = assert_raises(error_class) { client.lookup('reader@example.org') }
        refute_includes error.message, 'remote secret'
      end
    end
  end

  def test_invalid_json_and_nonobject_responses_are_retryable
    ['<html>secret</html>', 'null', '[]', 'true', '{'].each do |body|
      with_response(body, raw: true) do
        error = assert_raises(Sync::Unavailable) { client.lookup('reader@example.org') }
        refute_includes error.message, body
      end
    end
  end

  def test_lookup_response_rejects_invalid_identity_email_and_plan
    { 'reader_id' => '12', 'participation_id' => 0, 'generation' => -1, 'name' => '',
      'email' => 'other@example.org', 'plan_fingerprint' => 'different' }.each do |key, value|
      with_response(@remote.merge(key => value)) do
        assert_raises(Sync::Conflict) { client.lookup('reader@example.org') }
      end
    end
  end

  def test_complete_response_counts_must_be_nonnegative_integers_and_match_unique_readings
    [{}, { 'added' => -1, 'existing' => 2 }, { 'added' => '1', 'existing' => 0 },
     { 'added' => 0, 'existing' => 0 }, { 'added' => 1.0, 'existing' => 0 }].each do |response|
      with_response(response) do
        assert_raises(Sync::Unavailable) { client.complete(@link, [[1, 'nt', 0]]) }
      end
    end
  end

  def test_response_size_is_bounded_with_and_without_content_length
    with_response('x', raw: true, length: (Auth::MAX_BYTES + 1).to_s) do
      assert_raises(Sync::Unavailable) { client.lookup('reader@example.org') }
    end
    with_response(['x' * Auth::MAX_BYTES, 'x'], raw: true) do
      assert_raises(Sync::Unavailable) { client.lookup('reader@example.org') }
    end
  end

  def test_request_size_and_batch_length_are_bounded_before_network
    Net::HTTP.stub(:new, ->(*) { flunk 'oversized requests must not reach the network' }) do
      assert_raises(Sync::Conflict) { client.complete(@link, Array.new(5001) { [1, 'nt', 0] }) }
      assert_raises(Sync::Conflict) { client.complete(@link, [[1, 'x' * Auth::MAX_BYTES, 0]]) }
    end
  end

  def test_connection_tls_and_timeout_failures_are_sanitized_and_retryable
    [Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, SocketError, EOFError, Errno::ECONNREFUSED].each do |error_class|
      Net::HTTP.stub(:new, ->(*) { raise error_class, 'raw sensitive transport detail' }) do
        error = assert_raises(Sync::Unavailable) { client.lookup('reader@example.org') }
        refute_includes error.full_message, 'sensitive'
      end
    end
  end

  def test_total_timeout_bounds_a_slow_trickled_response_and_closes_the_connection
    response = Response.new(200, [])
    chunks_read = 0
    response.define_singleton_method(:read_body) do |&block|
      1000.times do
        sleep 0.01
        chunks_read += 1
        block.call(' ')
      end
    end
    http = HTTP.new(response)
    closed = false
    http.define_singleton_method(:start) do |&block|
      block.call(self)
    ensure
      closed = true
    end
    timeout = Timeout.method(:timeout)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Net::HTTP.stub(:new, http) do
      Timeout.stub(:timeout, ->(seconds, &block) {
        assert_equal 30, seconds
        assert_operator seconds, :<, Sync::LEASE_SECONDS
        timeout.call(0.08, &block)
      }) do
        error = assert_raises(Sync::Unavailable) { client.lookup('reader@example.org') }
        assert_equal 'Progress sync destination could not be reached securely', error.message
      end
    end
    assert closed
    assert_operator chunks_read, :>, 0
    assert_operator chunks_read, :<, 1000
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  def test_total_timeout_also_covers_connection_setup
    http = HTTP.new(nil)
    http.define_singleton_method(:start) { sleep 10 }
    timeout = Timeout.method(:timeout)
    Net::HTTP.stub(:new, http) do
      Timeout.stub(:timeout, ->(_seconds, &block) { timeout.call(0.02, &block) }) do
        assert_raises(Sync::Unavailable) { client.lookup('reader@example.org') }
      end
    end
  end

  def test_invalid_email_is_rejected_before_network
    Net::HTTP.stub(:new, ->(*) { flunk 'invalid emails must not reach the network' }) do
      [nil, '', 'reader', 'reader@ example.org', 'x' * 321].each do |email|
        assert_raises(Sync::Conflict) { client.lookup(email) }
      end
    end
  end

  def test_hmac_binds_all_fields_and_enforces_timestamp_window
    body = '{}'
    headers = Auth.headers(secret: 's' * 32, source: 'source-instance', method: 'POST', path: '/mount/progress-sync/lookup', body: body, timestamp: '1000')
    args = { headers: headers, sources: { 'source-instance' => { secret: 's' * 32 } }, method: 'POST',
             path: '/mount/progress-sync/lookup', body: body, now: 1000 }
    assert_equal 'source-instance', Auth.authenticate!(**args)
    [700, 1300].each { |now| assert_equal 'source-instance', Auth.authenticate!(**args, now: now) }
    [{ now: 699 }, { now: 1301 }, { body: '{"x":1}' }, { path: '/other/progress-sync/lookup' }, { method: 'GET' }].each do |change|
      assert_raises(Sync::Unauthorized) { Auth.authenticate!(**args, **change) }
    end
    [Auth::SOURCE_HEADER, Auth::VERSION_HEADER, Auth::SIGNATURE_HEADER].each do |key|
      assert_raises(Sync::Unauthorized) { Auth.authenticate!(**args, headers: headers.merge(key => 'tampered')) }
    end
    assert_raises(Sync::Unauthorized) { Auth.authenticate!(**args, sources: { 'source-instance' => { secret: 'x' * 31 } }) }
  end

private

  def client = Sync::Client.new('church')

  def with_response(payload, status: 200, raw: false, length: nil)
    http = HTTP.new(Response.new(status, raw ? payload : JSON.generate(payload), length))
    arguments = []
    Net::HTTP.stub(:new, ->(*args) {
      arguments.concat(args)
      http
    }) { yield http, arguments }
  end
end
