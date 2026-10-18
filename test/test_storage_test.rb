# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'

class TestStorageTest < Minitest::Test
  def test_active_storage_uses_this_processes_temporary_directory
    needs_rails!

    root = ENV.fetch('BIBLE270_TEST_STORAGE_ROOT')
    assert_equal root, ActiveStorage::Blob.service.root.to_s
    assert File.directory?(root)
    assert_equal File.expand_path('dummy/tmp/storage', __dir__), File.dirname(root)
  end

  def test_subprocesses_use_distinct_storage_and_clean_up_after_success_and_failure
    needs_rails!

    parent_root = ENV.fetch('BIBLE270_TEST_STORAGE_ROOT')
    sentinel = File.join(parent_root, 'isolation-check')
    File.write(sentinel, 'parent upload')
    roots = [false, true].map do |fail_test|
      stdout, stderr, status = run_storage_probe(fail_test: fail_test)
      assert_equal fail_test ? 1 : 0, status.exitstatus, "#{stdout}\n#{stderr}"
      assert_includes stdout, 'STORAGE_PROBE_UPLOADED'
      root = stdout[%r{^STORAGE_PROBE_ROOT=(.+)$}, 1]
      refute_nil root, stdout
      refute_equal parent_root, root
      refute File.exist?(root), 'the child must remove its storage after tests finish'
      assert_equal 'parent upload', File.read(sentinel), 'child cleanup must not touch another process'
      root
    end
    assert_equal 2, roots.uniq.size
  ensure
    FileUtils.rm_f(sentinel) if sentinel
  end

private

  def run_storage_probe(fail_test:)
    script = <<~'RUBY'
      require 'test_helper'
      abort 'Rails unavailable in storage probe' unless RAILS_LOADED
      puts "STORAGE_PROBE_ROOT=#{ENV.fetch('BIBLE270_TEST_STORAGE_ROOT')}"

      class StorageProbeTest < Minitest::Test
        def test_upload
          service = ActiveStorage::Blob.service
          service.upload('storage-probe', StringIO.new('test upload'))
          assert_equal 'test upload', service.download('storage-probe')
          puts 'STORAGE_PROBE_UPLOADED'
          flunk 'intentional failure to verify cleanup' if ENV['STORAGE_PROBE_FAIL'] == '1'
        end

        def teardown
          assert ActiveStorage::Blob.service.exist?('storage-probe'), 'storage must survive until teardown'
        end
      end
    RUBY
    Open3.capture3(
      { 'SKIP_COV' => '1', 'RECORD_RUNTIME' => nil, 'STORAGE_PROBE_FAIL' => fail_test ? '1' : '0' },
      RbConfig.ruby, '-I', __dir__, '-e', script
    )
  end
end
