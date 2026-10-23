# frozen_string_literal: true

require 'test_helper'
require 'rake'
require 'bible270/avatar_backfill'
require 'image_processing/vips'

class AvatarBackfillOptionsTest < Minitest::Test
  def test_batch_size_rejects_invalid_or_unbounded_values
    [nil, '', '0', '-1', '1001', '1.5', '2junk', ' 2', '+2', '1e2', 0, -1, 1001, 2.5].each do |value|
      error = assert_raises(Bible270::AvatarBackfill::Error) do
        Bible270::AvatarBackfill.new(batch_size: value)
      end
      assert_match(%r{BATCH_SIZE.*1.*1000}, error.message)
    end
  end

  def test_batch_size_accepts_bounded_integers_and_environment_strings
    [1, 100, 1000, '1', '100', '1000'].each do |value|
      assert_instance_of Bible270::AvatarBackfill, Bible270::AvatarBackfill.new(batch_size: value)
    end
  end
end

if RAILS_LOADED
  Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
  load File.expand_path('../lib/tasks/bible270_avatars.rake', __dir__) unless
    Rake::Task.task_defined?('bible270:avatars:optimize')

  class AvatarTasksTest < Minitest::Test
    def setup
      needs_rails!
      clear_engine_tables!
      @readers = []
      @extra_blobs = []
      @previous_env = %w[DRY_RUN FORCE BATCH_SIZE].to_h { |key| [key, ENV.delete(key)] }
      task.reenable
    end

    def teardown
      @previous_env&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      @readers&.each do |reader|
        next unless Bible270::Reader.avatar_uploads?

        ActiveStorage::Attachment.where(record_type: Bible270::Reader.polymorphic_name,
                                        record_id: reader.id).each(&:purge)
      end
      @extra_blobs&.each(&:purge)
    end

    def test_task_uses_host_environment
      assert_includes task.prerequisites, 'environment'
    end

    def test_task_succeeds_when_only_provider_links_exist
      needs_storage!
      provider = create_reader(avatar: false, image: 'https://private.example/avatar.png')
      output, = capture_io { task.invoke }
      assert_includes output, 'processed=0 skipped=0 changed=0 failed=0'
      refute_includes output, "reader_id=#{provider.id} "
      refute_match(%r{https?://|@}, output)
    end

    def test_task_environment_defaults_and_explicit_flags
      [[{}, false, false, 100],
       [{ 'DRY_RUN' => '1', 'FORCE' => '1', 'BATCH_SIZE' => '7' }, true, true, '7'],
       [{ 'DRY_RUN' => '0', 'FORCE' => '0' }, false, false, 100]].each do |env, dry_run, force, batch_size|
        %w[DRY_RUN FORCE BATCH_SIZE].each { |key| ENV.delete(key) }
        ENV.update(env)
        runner = Minitest::Mock.new
        runner.expect(:run, { failed: 0 })
        build = ->(**options) do
          assert_equal({ dry_run: dry_run, force: force, batch_size: batch_size }, options)
          runner
        end
        Bible270::AvatarBackfill.stub(:new, build) { task.invoke }
        runner.verify
        task.reenable
      end
    end

    def test_task_reports_actionable_error_without_active_storage
      Bible270::Reader.stub(:avatar_uploads?, false) do
        error = assert_raises(Bible270::AvatarBackfill::Error) { task.invoke }
        assert_match(%r{Active Storage}, error.message)
        assert_match(%r{active_storage/engine}, error.message)
        assert_match(%r{active_storage:install.*db:migrate}, error.message)
      end
    end

    def test_task_reports_actionable_error_without_active_storage_tables
      needs_storage!
      ActiveStorage::Attachment.stub(:table_exists?, false) do
        error = assert_raises(Bible270::AvatarBackfill::Error) { task.invoke }
        assert_match(%r{Active Storage.*db:migrate}, error.message)
      end
    end

    def test_invalid_batch_size_fails_before_querying_readers
      ENV['BATCH_SIZE'] = '1001'
      Bible270::Reader.stub(:with_avatar, -> { flunk 'must validate before querying readers' }) do
        error = assert_raises(Bible270::AvatarBackfill::Error) { task.invoke }
        assert_match(%r{BATCH_SIZE}, error.message)
      end
    end

    def test_dry_run_reports_only_ids_and_eligibility_without_storage_access_or_mutations
      needs_images!
      pending = create_reader
      current = create_reader
      Bible270::AvatarImages.optimize_existing!(current)
      provider = create_reader(avatar: false, image: 'https://private.example/avatar.png')
      before = database_snapshot
      ENV['DRY_RUN'] = '1'
      no_storage = ->(*) { flunk 'dry-run must not access storage or optimize images' }
      service = ActiveStorage::Blob.service
      output = nil

      Bible270::AvatarImages.stub(:optimize_existing!, no_storage) do
        Bible270::AvatarOptimizer.stub(:open, no_storage) do
          service.stub(:download, no_storage) do
            service.stub(:open, no_storage) do
              service.stub(:upload, no_storage) do
                service.stub(:delete, no_storage) do
                  output, = capture_io { task.invoke }
                end
              end
            end
          end
        end
      end

      assert_includes output, "reader_id=#{pending.id} eligible"
      assert_includes output, "reader_id=#{current.id} skipped"
      refute_includes output, "reader_id=#{provider.id} "
      assert_includes output, 'DRY RUN: eligible=1 skipped=1 processed=0 changed=0 failed=0'
      refute_match(%r{bytes|https?://|@}, output)
      assert_equal before, database_snapshot
    end

    def test_force_dry_run_marks_current_derivative_eligible_without_calling_service
      needs_images!
      reader = create_reader
      Bible270::AvatarImages.optimize_existing!(reader)
      ENV['DRY_RUN'] = ENV['FORCE'] = '1'
      Bible270::AvatarImages.stub(:optimize_existing!, ->(*) { flunk 'dry-run called service' }) do
        output, = capture_io { task.invoke }
        assert_includes output, "reader_id=#{reader.id} eligible"
        assert_includes output, 'eligible=1 skipped=0'
      end
    end

    def test_real_task_optimizes_only_original_reader_avatars_and_rerun_skips
      needs_images!
      reader = create_reader
      original = reader.avatar.blob
      original_bytes = original.download
      provider = create_reader(avatar: false, image: 'https://private.example/avatar.png')
      blank = create_reader(avatar: false)
      thumbnail_only = create_reader(avatar: false)
      thumbnail_only.avatar_thumbnail.attach(io: StringIO.new(png), filename: 'old.png', content_type: 'image/png')
      unrelated = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: 'unrelated.png', content_type: 'image/png')
      @extra_blobs << unrelated
      # Even an attachment named avatar on a different polymorphic type is out of scope.
      owner = HostUser.create!(name: 'Unrelated host user')
      other_attachment = ActiveStorage::Attachment.create!(name: 'avatar', record: owner, blob: unrelated)
      unrelated_ids = [unrelated.id, thumbnail_only.avatar_thumbnail.blob.id]

      output, = capture_io { task.invoke }

      assert_includes output, 'processed=1 skipped=0 changed=0 failed=0'
      [provider, blank, thumbnail_only].each { |excluded| refute_includes output, "reader_id=#{excluded.id} " }
      reader.reload
      assert reader.avatar_optimized?
      assert_equal original.id, reader.avatar.blob.id
      assert_equal original_bytes, reader.avatar.download
      assert_equal 'image/webp', reader.avatar_thumbnail.blob.content_type
      assert_includes output, "original=#{original.byte_size} optimized=#{reader.avatar_thumbnail.blob.byte_size}"
      assert_includes output, 'Originals retained.'
      derivative_id = reader.avatar_thumbnail.blob.id
      assert_equal unrelated_ids, [unrelated.reload.id, thumbnail_only.reload.avatar_thumbnail.blob.id]
      assert ActiveStorage::Attachment.exists?(other_attachment.id)

      task.reenable
      Bible270::AvatarOptimizer.stub(:open, ->(*) { flunk 'current derivative must not be reprocessed' }) do
        output, = capture_io { task.invoke }
        assert_includes output, 'processed=0 skipped=1 changed=0 failed=0'
      end
      assert_equal derivative_id, reader.reload.avatar_thumbnail.blob.id
    ensure
      other_attachment&.delete
      owner&.delete
    end

    def test_force_reprocesses_current_derivative_and_preserves_original
      needs_images!
      reader = create_reader
      Bible270::AvatarImages.optimize_existing!(reader)
      original_id = reader.avatar.blob.id
      optimizer = Bible270::AvatarOptimizer.method(:open)
      calls = 0
      ENV['FORCE'] = '1'
      wrapper = ->(*args, **kwargs, &block) do
        calls += 1
        optimizer.call(*args, **kwargs, &block)
      end
      Bible270::AvatarOptimizer.stub(:open, wrapper) do
        output, = capture_io { task.invoke }
        assert_includes output, 'processed=1 skipped=0 changed=0 failed=0'
      end
      assert_equal 1, calls
      assert_equal original_id, reader.reload.avatar.blob.id
      assert reader.avatar_optimized?
    end

    def test_optimizer_version_change_makes_existing_derivative_eligible_again
      needs_images!
      reader = create_reader
      Bible270::AvatarImages.optimize_existing!(reader)
      optimizer = Bible270::AvatarOptimizer
      previous_version = optimizer::VERSION
      optimizer.send(:remove_const, :VERSION)
      optimizer.const_set(:VERSION, "#{previous_version}-backfill-test")

      refute reader.reload.avatar_optimized?
      output, = capture_io { task.invoke }
      assert_includes output, 'processed=1 skipped=0 changed=0 failed=0'
      assert reader.reload.avatar_optimized?
    ensure
      if previous_version
        optimizer.send(:remove_const, :VERSION)
        optimizer.const_set(:VERSION, previous_version)
      end
    end

    def test_replaced_original_makes_existing_derivative_eligible_again
      needs_images!
      reader = create_reader
      Bible270::AvatarImages.optimize_existing!(reader)
      reader.avatar.attach(io: StringIO.new(png), filename: 'replacement.png', content_type: 'image/png')
      replacement_id = reader.avatar.blob.id

      refute reader.reload.avatar_optimized?
      output, = capture_io { task.invoke }
      assert_includes output, 'processed=1 skipped=0 changed=0 failed=0'
      assert reader.reload.avatar_optimized?
      assert_equal replacement_id, reader.avatar.blob.id
    end

    def test_changed_original_is_reported_without_counting_display_bytes
      needs_images!
      reader = create_reader
      original_id = reader.avatar.blob.id
      result = { status: :changed, before_bytes: 100, after_bytes: 50 }
      Bible270::AvatarImages.stub(:optimize_existing!, result) do
        output = StringIO.new
        summary = Bible270::AvatarBackfill.new(output: output).run
        assert_equal 1, summary[:changed]
        assert_equal 0, summary[:processed]
        assert_equal 0, summary[:failed]
        assert_equal 0, summary[:original_bytes]
        assert_equal 0, summary[:optimized_bytes]
        assert_includes output.string, "reader_id=#{reader.id} changed"
      end
      assert_equal original_id, reader.reload.avatar.blob.id
    end

    def test_expected_failures_are_sanitized_and_processing_continues_with_nonzero_task_result
      needs_images!
      readers = 4.times.map { create_reader }
      private_message = 'private@example.org https://secret.example/avatar native decoder /private/image.png'
      failures = [Bible270::AvatarOptimizer::Error.new(private_message),
                  Bible270::AvatarImages::Error.new(private_message),
                  ActiveRecord::StatementInvalid.new(private_message)]
      seen = []
      service = ->(reader, force:) do
        refute force
        seen << reader.id
        index = readers.index { |candidate| candidate.id == reader.id }
        raise failures[index] if index < failures.size

        { status: :optimized, before_bytes: 123, after_bytes: 45 }
      end
      Bible270::AvatarImages.stub(:optimize_existing!, service) do
        summary = Bible270::AvatarBackfill.new(output: StringIO.new).run
        assert_equal 3, summary[:failed]
        assert_equal 1, summary[:processed]
        assert_equal 123, summary[:original_bytes]
        assert_equal 45, summary[:optimized_bytes]
        assert_equal readers.map(&:id), seen
        seen.clear

        output, errors = capture_io do
          error = assert_raises(Bible270::AvatarBackfill::Error) { task.invoke }
          assert_match(%r{failed for 3 reader}, error.message)
          assert_nil error.cause
        end
        assert_equal readers.map(&:id), seen
        assert_includes output, 'processed=1 skipped=0 changed=0 failed=3'
        assert_match(%r{image processing failed}, output)
        assert_match(%r{storage failed}, output)
        assert_match(%r{database failed}, output)
        refute_match(%r{private@example|https://|native decoder|/private/}, output + errors)
      end
    end

    def test_corrupt_original_does_not_prevent_later_real_image_from_being_optimized
      needs_images!
      bad = create_reader(avatar: false)
      bad.avatar.attach(io: StringIO.new('not a PNG'), filename: 'private.png', content_type: 'image/png')
      good = create_reader
      original_id = bad.avatar.blob.id
      output, = capture_io { assert_raises(Bible270::AvatarBackfill::Error) { task.invoke } }
      assert_includes output, 'processed=1 skipped=0 changed=0 failed=1'
      assert_equal original_id, bad.reload.avatar.blob.id
      refute bad.avatar_thumbnail.attached?
      assert good.reload.avatar_optimized?
    end

    def test_runner_batches_preloaded_readers_sequentially
      needs_images!
      readers = 5.times.map { create_reader }
      relation = Bible270::Reader.with_avatar.joins(:avatar_attachment)
      find_each = relation.method(:find_each)
      sizes = []
      seen = []
      batching = ->(batch_size:, &block) do
        sizes << batch_size
        find_each.call(batch_size: batch_size, &block)
      end
      service = ->(reader, force:) do
        refute force
        assert reader.association(:avatar_attachment).loaded?
        assert reader.association(:avatar_thumbnail_attachment).loaded?
        assert reader.avatar_attachment.association(:blob).loaded?
        seen << reader.id
        { status: :optimized, before_bytes: 10, after_bytes: 5 }
      end
      ENV['BATCH_SIZE'] = '2'
      Bible270::Reader.stub(:with_avatar, relation) do
        relation.stub(:joins, relation) do
          relation.stub(:find_each, batching) do
            Bible270::AvatarImages.stub(:optimize_existing!, service) do
              output, = capture_io { task.invoke }
              assert_includes output, 'processed=5 skipped=0 changed=0 failed=0'
              assert_includes output, 'original=50 optimized=25'
            end
          end
        end
      end
      assert_equal [2], sizes
      assert_equal readers.map(&:id), seen
    end

  private

    def task = Rake::Task['bible270:avatars:optimize']

    def needs_storage!
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?
    end

    def needs_images!
      needs_storage!
      skip 'AvatarImages implementation is pending' unless defined?(Bible270::AvatarImages)
    end

    def png
      @png ||= Vips::Image.black(8, 6, bands: 3).pngsave_buffer
    end

    def create_reader(avatar: true, image: nil)
      email = "avatar-task-#{@readers.length}@example.org"
      reader = Bible270::Reader.create!(provider: 'email', uid: email, email: email,
                                        display_name: 'Private Reader', avatar_url: image)
      @readers << reader
      reader.avatar.attach(io: StringIO.new(png), filename: 'legacy.png', content_type: 'image/png') if avatar
      reader
    end

    def database_snapshot
      [Bible270::Reader.order(:id).map(&:attributes),
       ActiveStorage::Attachment.order(:id).map(&:attributes),
       ActiveStorage::Blob.order(:id).map(&:attributes)]
    end
  end
end
