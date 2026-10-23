# frozen_string_literal: true

require 'test_helper'
require 'bible270/avatar_images'
require 'image_processing/vips'
require 'zlib'

if RAILS_LOADED
  class AvatarImagesTest < ActiveSupport::TestCase
    include Bible270::PlanHelper
    include ActiveJob::TestHelper

    # Uploads must own their transaction; exercise real commits and explicit rollbacks.
    self.use_transactional_tests = false

    def setup
      needs_rails!
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      clear_engine_tables!
      @initial_blob_ids = ActiveStorage::Blob.pluck(:id)
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'avatar@example.org',
                                         display_name: 'Original Reader', first_name: 'Original', last_name: 'Reader')
    end

    def teardown
      return unless @reader

      ActiveStorage::Attachment.where(record: @reader).delete_all
      ActiveStorage::Blob.where.not(id: @initial_blob_ids).each(&:purge)
    end

    def main_app = Rails.application.routes.url_helpers

    def test_update_preserves_original_and_uploads_both_files_before_switching_attachments
      seed_images
      before = snapshot
      uploads = []
      service = ActiveStorage::Blob.service
      upload_file = service.method(:upload)
      observe = ->(key, io, **options) do
        assert_equal before, snapshot
        upload_file.call(key, io, **options)
        uploads << key
      end
      service.stub(:upload, observe) do
        with_upload(contents: png([210, 30, 60])) do |upload|
          Bible270::AvatarImages.update!(@reader, { display_name: 'Changed Reader' }, upload: upload)
        end
      end

      assert_equal 2, uploads.size
      assert_equal 'Changed Reader', @reader.reload.display_name
      assert_equal png([210, 30, 60]), @reader.avatar.download
      assert_equal 'portrait.png', @reader.avatar.filename.to_s
      assert_equal 'image/png', @reader.avatar.content_type
      assert_equal [480, 320], dimensions(@reader.avatar.download)
      assert_thumbnail
      assert_equal uploads, [@reader.avatar.blob.key, @reader.avatar_thumbnail.blob.key]
    end

    def test_compressed_text_png_upload_never_queues_or_runs_native_analysis_after_commit
      bytes = png_with_compressed_text
      assert_operator bytes.bytesize, :<, 16 * 1024
      assert_includes bytes, 'zTXt'
      refute @reader.avatar_uploaded?
      refute @reader.class.connection_pool.with_connection(&:transaction_open?)
      assert_instance_of ActiveJob::QueueAdapters::TestAdapter, ActiveStorage::AnalyzeJob.queue_adapter
      analyzer = ActiveStorage::Analyzer::ImageAnalyzer::Vips
      analyzer_calls = []
      forbid_analysis = ->(blob) do
        analyzer_calls << blob.id
        flunk "Active Storage must not decode uploaded avatar blob #{blob.id} (#{blob.filename})"
      end
      ActiveStorage.stub(:variant_processor, :vips) do
        ActiveStorage.stub(:analyzers, [analyzer]) do
          analyzer.stub(:new, forbid_analysis) do
            assert_no_enqueued_jobs(only: ActiveStorage::AnalyzeJob) do
              assert_no_performed_jobs(only: ActiveStorage::AnalyzeJob) do
                # No seed attachments: execute all newly enqueued jobs, including
                # commit callbacks, without processing unrelated legacy originals.
                perform_enqueued_jobs do
                  with_upload(contents: bytes) do |upload|
                    Bible270::AvatarImages.update!(@reader, {}, upload: upload)
                  end
                end
              end
            end
          end
        end
      end

      assert_empty analyzer_calls
      refute @reader.class.connection_pool.with_connection(&:transaction_open?)
      @reader.reload
      assert_one_attachment_each
      assert_equal bytes, @reader.avatar.download
      assert_equal 'image/png', @reader.avatar.content_type
      assert_equal true, @reader.avatar.blob.metadata['analyzed']
      refute @reader.avatar.blob.metadata.key?('width')
      refute @reader.avatar.blob.metadata.key?('height')
      assert_equal true, @reader.avatar_thumbnail.blob.metadata['analyzed']
      assert_thumbnail
    end

    def test_upload_after_another_upload_replaces_populated_cached_attachments_without_duplicates
      seed_images
      assert_stale_upload_replaces_images(concurrent_action: :upload, cached_original: true, cached_thumbnail: true)
    end

    def test_upload_after_another_upload_replaces_cached_nil_attachments_without_duplicates
      assert_stale_upload_replaces_images(concurrent_action: :upload, cached_original: false, cached_thumbnail: false)
    end

    def test_upload_after_backfill_replaces_populated_cached_attachments_without_duplicates
      seed_images
      assert_stale_upload_replaces_images(concurrent_action: :backfill, cached_original: true, cached_thumbnail: true)
    end

    def test_upload_after_backfill_replaces_a_cached_nil_thumbnail_without_duplicates
      seed_original
      assert_stale_upload_replaces_images(concurrent_action: :backfill, cached_original: true, cached_thumbnail: false)
    end

    def test_upload_rejects_a_caller_owned_transaction_before_processing_or_storage
      seed_images
      with_upload do |upload|
        assert_outer_transaction_rejected do
          Bible270::AvatarImages.update!(@reader, { display_name: 'Must not be saved' }, upload: upload)
        end
      end
    end

    def test_backfill_rejects_a_caller_owned_transaction_before_processing_or_storage
      seed_original
      assert_outer_transaction_rejected { Bible270::AvatarImages.optimize_existing!(@reader) }
    end

    def test_update_without_upload_preserves_both_images_without_processing_or_storage_writes
      seed_images
      ids = image_ids
      without_processing_or_storage do
        Bible270::AvatarImages.update!(@reader, { display_name: 'Changed Reader' })
      end

      assert_equal 'Changed Reader', @reader.reload.display_name
      assert_equal ids, image_ids
    end

    def test_model_validation_happens_before_processing_or_storage
      seed_images
      before = snapshot
      without_processing_or_storage do
        with_upload do |upload|
          assert_raises(ActiveRecord::RecordInvalid) do
            Bible270::AvatarImages.update!(@reader, { display_name: '' }, upload: upload)
          end
        end
      end
      assert_equal before, snapshot
    end

    def test_malformed_bytes_leave_all_attributes_and_both_images_unchanged
      seed_images
      before = snapshot
      without_storage_writes do
        with_upload(contents: 'not a PNG') do |upload|
          assert_raises(Bible270::AvatarOptimizer::Error) do
            Bible270::AvatarImages.update!(@reader, { display_name: 'Changed Reader' }, upload: upload)
          end
        end
      end
      assert_equal before, snapshot
    end

    def test_attach_avatar_compatibility_preserves_original_and_builds_thumbnail
      with_upload { |upload| assert @reader.attach_avatar(upload) }

      assert_equal png, @reader.reload.avatar.download
      assert_thumbnail
      before = snapshot
      without_storage_writes do
        with_upload(contents: 'broken image') { |upload| refute @reader.attach_avatar(upload) }
      end
      assert_match(%r{Avatar.*decode}, @reader.errors[:avatar].join)
      assert_equal before, snapshot
    end

    def test_upload_without_active_storage_raises_an_actionable_error_before_assignment
      before = snapshot
      Bible270::Reader.stub(:avatar_uploads?, false) do
        without_processing_or_storage do
          with_upload do |upload|
            error = assert_raises(Bible270::AvatarImages::Error) do
              Bible270::AvatarImages.update!(@reader, { display_name: 'Changed Reader' }, upload: upload)
            end
            assert_match(%r{uploads require Active Storage}, error.message)
            refute @reader.attach_avatar(upload)
          end
        end
      end
      assert_equal 'Original Reader', @reader.display_name
      assert_equal before, snapshot
    end

    def test_backfill_preserves_original_blob_attachment_metadata_and_bytes
      seed_original
      original = [@reader.avatar.attachment.attributes, @reader.avatar.blob.attributes, @reader.avatar.download]
      result = Bible270::AvatarImages.optimize_existing!(@reader)

      assert_equal :optimized, result[:status]
      assert_equal png.bytesize, result[:before_bytes]
      assert_equal @reader.avatar_thumbnail.blob.byte_size, result[:after_bytes]
      assert_equal original, [@reader.avatar.attachment.attributes, @reader.avatar.blob.attributes, @reader.avatar.download]
      assert_thumbnail
    end

    def test_backfill_is_idempotent_without_reprocessing_or_storage_writes
      seed_images
      before = snapshot
      result = nil
      without_processing_or_storage do
        result = Bible270::AvatarImages.optimize_existing!(@reader)
      end

      assert_equal({ status: :skipped, before_bytes: @reader.avatar.byte_size,
                     after_bytes: @reader.avatar_thumbnail.byte_size }, result)
      assert_equal before, snapshot
    end

    def test_backfill_without_original_skips_without_processing_or_storage_writes
      without_processing_or_storage do
        assert_equal({ status: :skipped, before_bytes: 0, after_bytes: 0 },
                     Bible270::AvatarImages.optimize_existing!(@reader))
      end
    end

    def test_backfill_replaces_an_outdated_version_and_does_not_display_it
      seed_images
      original_id, thumbnail_id = image_ids
      thumbnail = @reader.avatar_thumbnail.blob
      thumbnail.update!(metadata: thumbnail.metadata.merge('bible270_avatar_version' => 'outdated'))
      @reader.reload
      refute @reader.avatar_optimized?
      assert_equal blob_path(@reader.avatar), b270_avatar_src(@reader)

      assert_equal :optimized, Bible270::AvatarImages.optimize_existing!(@reader)[:status]
      assert_equal original_id, @reader.reload.avatar.blob.id
      refute_equal thumbnail_id, @reader.avatar_thumbnail.blob.id
      assert_thumbnail
    end

    def test_force_rebuilds_current_thumbnail_without_replacing_original
      seed_images
      original_id, thumbnail_id = image_ids
      original_bytes = @reader.avatar.download

      result = Bible270::AvatarImages.optimize_existing!(@reader, force: true)

      assert_equal :optimized, result[:status]
      assert_equal original_id, @reader.reload.avatar.blob.id
      assert_equal original_bytes, @reader.avatar.download
      refute_equal thumbnail_id, @reader.avatar_thumbnail.blob.id
      assert_thumbnail
    end

    def test_direct_original_replacement_never_displays_a_stale_thumbnail
      seed_images
      thumbnail_id = @reader.avatar_thumbnail.blob.id
      @reader.avatar.attach(io: StringIO.new(png([210, 30, 60])), filename: 'replacement.png', content_type: 'image/png')
      @reader.reload

      assert_equal thumbnail_id, @reader.avatar_thumbnail.blob.id
      refute @reader.avatar_optimized?
      assert_equal @reader.avatar.blob.id, @reader.display_avatar.blob.id
      assert_equal blob_path(@reader.avatar), b270_avatar_src(@reader)
      refute_equal blob_path(@reader.avatar_thumbnail), b270_avatar_src(@reader)

      assert_equal :optimized, Bible270::AvatarImages.optimize_existing!(@reader)[:status]
      assert_thumbnail
    end

    def test_backfill_discards_its_thumbnail_when_original_is_replaced_during_processing
      seed_original
      replacement = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png([210, 30, 60])),
                                                           filename: 'replacement.png', content_type: 'image/png')
      blob_ids = ActiveStorage::Blob.order(:id).pluck(:id)
      result = nil
      track_uploads do |keys|
        during_processing(-> { Bible270::Reader.find(@reader.id).avatar.attach(replacement) }) do
          result = Bible270::AvatarImages.optimize_existing!(@reader)
        end
        assert_discarded keys
      end

      assert_equal :changed, result[:status]
      assert_equal blob_ids, ActiveStorage::Blob.order(:id).pluck(:id)
      assert_equal replacement.id, @reader.reload.avatar.blob.id
      assert_equal png([210, 30, 60]), @reader.avatar.download
      refute @reader.avatar_thumbnail.attached?
    end

    def test_backfill_discards_its_thumbnail_when_original_is_removed_during_processing
      seed_images
      blob_ids = ActiveStorage::Blob.order(:id).pluck(:id)
      result = nil
      track_uploads do |keys|
        during_processing(-> { Bible270::AvatarImages.remove!(Bible270::Reader.find(@reader.id)) }) do
          result = Bible270::AvatarImages.optimize_existing!(@reader, force: true)
        end
        assert_discarded keys
      end

      assert_equal :changed, result[:status]
      assert_equal blob_ids, ActiveStorage::Blob.order(:id).pluck(:id)
      refute @reader.reload.avatar_uploaded?
      refute @reader.avatar_thumbnail.attached?
    end

    def test_concurrent_backfill_keeps_the_winning_thumbnail_and_cleans_up_the_loser
      seed_original
      winner_id = nil
      winner = -> do
        other = Bible270::Reader.find(@reader.id)
        assert_equal :optimized, Bible270::AvatarImages.optimize_existing!(other)[:status]
        winner_id = other.avatar_thumbnail.blob.id
      end
      result = nil
      assert_difference 'ActiveStorage::Blob.count', 1 do
        track_uploads do |keys|
          during_processing(winner) { result = Bible270::AvatarImages.optimize_existing!(@reader) }
          assert_equal 2, keys.size
          assert ActiveStorage::Blob.service.exist?(keys.first)
          assert_discarded keys.drop(1)
        end
      end

      assert_equal :skipped, result[:status]
      assert_equal winner_id, @reader.reload.avatar_thumbnail.blob.id
      assert_thumbnail
    end

    def test_update_transaction_rollback_restores_profile_and_both_attachments_and_discards_new_blobs
      seed_images
      before = snapshot
      save = @reader.method(:save!)
      rollback = -> do
        save.call
        raise ActiveRecord::RecordNotSaved.new('forced rollback after attachment changes', @reader)
      end
      assert_no_difference ['ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'] do
        track_uploads do |keys|
          @reader.stub(:save!, rollback) do
            with_upload do |upload|
              assert_raises(ActiveRecord::RecordNotSaved) do
                Bible270::AvatarImages.update!(@reader, { display_name: 'Changed Reader' }, upload: upload)
              end
            end
          end
          assert_equal 2, keys.size
          assert_discarded keys
        end
      end
      assert_equal before, snapshot
    end

    def test_backfill_transaction_rollback_restores_previous_thumbnail_and_discards_new_blob
      seed_images
      before = snapshot
      save = @reader.method(:save!)
      rollback = -> do
        save.call
        raise ActiveRecord::RecordNotSaved.new('forced rollback', @reader)
      end
      assert_no_difference ['ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'] do
        track_uploads do |keys|
          @reader.stub(:save!, rollback) do
            assert_raises(ActiveRecord::RecordNotSaved) do
              Bible270::AvatarImages.optimize_existing!(@reader, force: true)
            end
          end
          assert_equal 1, keys.size
          assert_discarded keys
        end
      end
      assert_equal before, snapshot
    end

    def test_an_after_commit_error_does_not_purge_the_new_live_images
      seed_images
      previous_ids = image_ids
      reader_id = @reader.id
      failure = ->(record) { raise IOError, 'after commit failed' if record.id == reader_id }
      Bible270::Reader.set_callback(:commit, :after, failure)
      begin
        track_uploads do |keys|
          with_upload(contents: png([210, 30, 60])) do |upload|
            error = assert_raises(IOError) do
              Bible270::AvatarImages.update!(@reader, { display_name: 'Changed Reader' }, upload: upload)
            end
            assert_equal 'after commit failed', error.message
          end
          assert_equal 2, keys.size
          keys.each do |key|
            assert ActiveStorage::Blob.exists?(key: key)
            assert ActiveStorage::Blob.service.exist?(key)
          end
        end
      ensure
        Bible270::Reader.skip_callback(:commit, :after, failure)
      end

      assert_equal 'Changed Reader', @reader.reload.display_name
      assert_equal png([210, 30, 60]), @reader.avatar.download
      refute_equal previous_ids.first, @reader.avatar.blob.id
      refute_equal previous_ids.last, @reader.avatar_thumbnail.blob.id
      assert_thumbnail
    end

    def test_partial_original_storage_failure_cleans_up_the_failed_blob
      assert_failed_upload_cleanup(fail_on: 1)
    end

    def test_partial_thumbnail_storage_failure_cleans_up_both_new_blobs
      assert_failed_upload_cleanup(fail_on: 2)
    end

    def test_partial_original_upload_and_failed_deletion_retain_a_retryable_blob_without_deleting_live_images
      assert_failed_cleanup_can_retry(fail_on: 1)
    end

    def test_partial_thumbnail_upload_and_failed_deletions_retain_both_retryable_blobs_without_deleting_live_images
      assert_failed_cleanup_can_retry(fail_on: 2)
    end

    def test_backfill_partial_storage_failure_keeps_previous_images_and_cleans_up_new_blob
      seed_images
      before = snapshot
      assert_no_difference ['ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'] do
        track_uploads(fail_on: 1) do |keys|
          error = assert_raises(Bible270::AvatarImages::Error) do
            Bible270::AvatarImages.optimize_existing!(@reader, force: true)
          end
          assert_match(%r{picture could not be stored}, error.message)
          assert_equal 1, keys.size
          assert_discarded keys
        end
      end
      assert_equal before, snapshot
    end

    def test_backfill_processor_failure_preserves_previous_images_without_storage_writes
      seed_images
      before = snapshot
      failure = ->(*) { raise Bible270::AvatarOptimizer::Error, 'processor unavailable' }
      without_storage_writes do
        Bible270::AvatarOptimizer.stub(:open, failure) do
          assert_raises(Bible270::AvatarOptimizer::Error) do
            Bible270::AvatarImages.optimize_existing!(@reader, force: true)
          end
        end
      end
      assert_equal before, snapshot
    end

    def test_remove_clears_both_attachments_in_one_transaction
      seed_images
      original_attributes = @reader.attributes.except('updated_at')
      Bible270::AvatarImages.remove!(@reader)

      refute @reader.reload.avatar_uploaded?
      refute @reader.avatar_thumbnail.attached?
      assert_equal original_attributes, @reader.attributes.except('updated_at')
      assert_empty ActiveStorage::Attachment.where(record: @reader)
    end

    def test_remove_rollback_restores_both_attachments
      seed_images
      before = snapshot
      save = @reader.method(:save!)
      rollback = -> do
        save.call
        raise ActiveRecord::RecordNotSaved.new('forced rollback', @reader)
      end
      without_storage_writes do
        @reader.stub(:save!, rollback) do
          assert_raises(ActiveRecord::RecordNotSaved) { Bible270::AvatarImages.remove!(@reader) }
        end
      end
      assert_equal before, snapshot
    end

  private

    def png(color = [35, 120, 210])
      Vips::Image.black(480, 320).new_from_image(color).write_to_buffer('.png')
    end

    def png_with_compressed_text
      deflater = Zlib::Deflate.new
      compressed = +''.b
      block = 'x' * (16 * 1024)
      16.times { compressed << deflater.deflate(block) }
      compressed << deflater.finish
      # Each valid zTXt chunk expands to 256 KiB; do not materialize the 8 MiB text.
      chunks = 32.times.map do |index|
        payload = "text#{index}\0\0".b + compressed
        data = 'zTXt'.b + payload
        [payload.bytesize].pack('N') + data + [Zlib.crc32(data)].pack('N')
      end.join
      Vips::Image.black(1, 1).new_from_image([35, 120, 210]).pngsave_buffer(strip: true).dup.insert(33, chunks)
    ensure
      deflater&.close
    end

    def with_upload(contents: png)
      Tempfile.create(['avatar-images-test-', '.png'], binmode: true) do |file|
        file.write(contents)
        file.rewind
        yield ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: 'portrait.png', type: 'image/png')
      end
    end

    def seed_original
      @reader.avatar.attach(io: StringIO.new(png), filename: 'legacy.png', content_type: 'image/png',
                            metadata: { 'legacy' => 'preserved' })
    end

    def seed_images
      with_upload { |upload| Bible270::AvatarImages.update!(@reader, {}, upload: upload) }
      @reader.reload
    end

    def snapshot
      reader = Bible270::Reader.find(@reader.id)
      [reader.attributes, [reader.avatar, reader.avatar_thumbnail].map do |image|
        [image.attachment.attributes, image.blob.attributes, image.download] if image.attached?
      end]
    end

    def image_ids
      [@reader.avatar.blob.id, @reader.avatar_thumbnail.blob.id]
    end

    def dimensions(bytes)
      image = Vips::Image.new_from_buffer(bytes, '')
      [image.width, image.height]
    end

    def blob_path(image)
      main_app.rails_blob_path(image, only_path: true)
    end

    def assert_thumbnail
      assert @reader.avatar_optimized?
      blob = @reader.avatar_thumbnail.blob
      assert_equal 'image/webp', blob.content_type
      assert_equal 'avatar.webp', blob.filename.to_s
      assert_equal @reader.avatar.blob.service_name, blob.service_name
      assert_equal @reader.avatar.blob.id, blob.metadata['bible270_avatar_source_id']
      assert_equal Bible270::AvatarOptimizer::VERSION, blob.metadata['bible270_avatar_version']
      image = Vips::Image.new_from_buffer(blob.download, '')
      assert_equal [256, 256], [image.width, image.height]
      assert_equal 'webpload_buffer', image.get('vips-loader')
      assert_equal 0, image.get_typeof('n-pages')
      assert_equal blob_path(@reader.avatar_thumbnail), b270_avatar_src(@reader)
    end

    def without_storage_writes(&block)
      writes = []
      subscriber = ->(*event) { writes << event.first }
      ActiveSupport::Notifications.subscribed(subscriber, %r{service_(upload|delete|delete_prefixed)\.active_storage}) do
        assert_no_difference ['ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'], &block
      end
      assert_empty writes
    end

    def without_processing_or_storage(&block)
      unexpected = ->(*) { flunk 'Processing must not run' }
      Bible270::AvatarOptimizer.stub(:open, unexpected) { without_storage_writes(&block) }
    end

    # Interleave a second reader instance after decoding, before the backfill's
    # locked compare-and-switch. This is deterministic and needs no SQLite threads.
    def during_processing(action, &block)
      process = Bible270::AvatarOptimizer.method(:open)
      invoked = false
      interleave = ->(*args, **options, &block) do
        process.call(*args, **options) do |output|
          unless invoked
            invoked = true
            action.call
          end
          block.call(output)
        end
      end
      Bible270::AvatarOptimizer.stub(:open, interleave, &block)
      assert invoked
    end

    def track_uploads(fail_on: nil)
      keys = []
      service = ActiveStorage::Blob.service
      upload = service.method(:upload)
      record = ->(key, io, **options) do
        keys << key
        upload.call(key, io, **options)
        # Fail after the backend has written bytes, not just before it is called.
        raise IOError, 'partial storage failure' if keys.size == fail_on
      end
      service.stub(:upload, record) { yield keys }
    end

    def assert_discarded(keys)
      refute_empty keys
      keys.each do |key|
        refute ActiveStorage::Blob.exists?(key: key)
        refute ActiveStorage::Blob.service.exist?(key), "unused file remains in storage: #{key}"
      end
    end

    def assert_stale_upload_replaces_images(concurrent_action:, cached_original:, cached_thumbnail:)
      stale = Bible270::Reader.with_avatar.find(@reader.id)
      assert stale.association(:avatar_attachment).loaded?
      assert stale.association(:avatar_thumbnail_attachment).loaded?
      assert_equal cached_original, stale.avatar.attached?
      assert_equal cached_thumbnail, stale.avatar_thumbnail.attached?
      cached_ids = [stale.avatar.attachment&.id, stale.avatar_thumbnail.attachment&.id]
      stale.bible_version = 'KJV'
      stale.daily_reminder_time = '06:45'
      attributes = { first_name: 'Changed', last_name: 'Reader', display_name: 'Changed Reader' }
      replacement_bytes = png([210, 30, 60])
      other_image_ids = nil
      concurrent_change = -> do
        other = Bible270::Reader.find(@reader.id)
        if concurrent_action == :upload
          with_upload do |upload|
            Bible270::AvatarImages.update!(other, { display_mode: 'dark_green' }, upload: upload)
          end
        else
          other.update!(display_mode: 'dark_green')
          assert_equal :optimized, Bible270::AvatarImages.optimize_existing!(other, force: cached_thumbnail)[:status]
        end
        other_image_ids = [other.avatar.blob.id, other.avatar_thumbnail.blob.id]
        assert_one_attachment_each
        assert_equal cached_ids, [stale.avatar.attachment&.id, stale.avatar_thumbnail.attachment&.id]
      end
      during_processing(concurrent_change) do
        with_upload(contents: replacement_bytes) do |upload|
          Bible270::AvatarImages.update!(stale, attributes, upload: upload)
        end
      end

      assert_one_attachment_each
      @reader.reload
      [stale, @reader].each do |reader|
        assert_equal attributes.stringify_keys, reader.attributes.slice(*attributes.keys.map(&:to_s))
        assert_equal 'KJV', reader.bible_version
        assert_equal '06:45', reader.daily_reminder_time
        assert_equal 'dark_green', reader.display_mode
        assert_equal replacement_bytes, reader.avatar.download
      end
      refute_equal other_image_ids.first, @reader.avatar.blob.id
      refute_equal other_image_ids.last, @reader.avatar_thumbnail.blob.id
      assert_thumbnail

      Bible270::AvatarImages.remove!(stale)
      assert_empty ActiveStorage::Attachment.where(record: @reader)
      refute @reader.reload.avatar_uploaded?
      refute @reader.avatar_thumbnail.attached?
      assert_equal 'Changed Reader', @reader.display_name
      assert_equal 'KJV', @reader.bible_version
      assert_equal '06:45', @reader.daily_reminder_time
      assert_equal 'dark_green', @reader.display_mode
    end

    def assert_one_attachment_each
      assert_equal({ 'avatar' => 1, 'avatar_thumbnail' => 1 },
                   ActiveStorage::Attachment.where(record: @reader).group(:name).count)
    end

    def assert_outer_transaction_rejected(&block)
      before = snapshot
      without_processing_or_storage do
        Bible270::Reader.transaction do
          @reader.update!(display_mode: 'dark_green')
          error = assert_raises(Bible270::AvatarImages::Error, &block)
          assert_match(%r{outside an existing database transaction}, error.message)
          assert_equal 'Original Reader', @reader.display_name
          assert_equal 'dark_green', Bible270::Reader.find(@reader.id).display_mode
          raise ActiveRecord::Rollback
        end
      end
      assert_equal before, snapshot
    end

    def assert_failed_cleanup_can_retry(fail_on:)
      seed_images
      before = snapshot
      live_blobs = [@reader.avatar.blob, @reader.avatar_thumbnail.blob]
      service = ActiveStorage::Blob.service
      retained_blobs = []
      failed_delete = ->(key) do
        blob = ActiveStorage::Blob.find_by!(key: key)
        refute_includes live_blobs.map(&:id), blob.id
        retained_blobs << blob
        raise IOError, 'storage deletion unavailable'
      end
      assert_difference 'ActiveStorage::Blob.count', fail_on do
        assert_no_difference 'ActiveStorage::Attachment.count' do
          service.stub(:delete, failed_delete) do
            track_uploads(fail_on: fail_on) do |keys|
              with_upload do |upload|
                error = assert_raises(Bible270::AvatarImages::Error) do
                  Bible270::AvatarImages.update!(@reader, { display_name: 'Must not be saved' }, upload: upload)
                end
                assert_match(%r{picture could not be stored}, error.message)
              end
              assert_equal fail_on, keys.size
              assert_equal keys, retained_blobs.map(&:key)
            end
          end
        end
      end
      assert_equal before, snapshot
      retained_blobs.each do |blob|
        assert blob.persisted?
        refute blob.destroyed?
        assert_empty blob.attachments
        stored = ActiveStorage::Blob.find(blob.id)
        assert_equal blob.key, stored.key
        assert_equal blob.service_name, stored.service_name
        assert stored.service.exist?(stored.key)
        assert_equal stored.byte_size, stored.download.bytesize
      end

      deleted_keys = []
      delete = service.method(:delete)
      retry_delete = ->(key) do
        assert ActiveStorage::Blob.exists?(key: key), 'Keep the retry record until storage deletion succeeds'
        deleted_keys << key
        delete.call(key)
      end
      assert_difference 'ActiveStorage::Blob.count', -fail_on do
        service.stub(:delete, retry_delete) do
          Bible270::AvatarImages.send(:discard_unattached, live_blobs + retained_blobs)
        end
      end
      assert_equal retained_blobs.map(&:key), deleted_keys
      assert_discarded deleted_keys
      assert retained_blobs.all?(&:destroyed?)
      assert_equal before, snapshot
      live_blobs.each do |blob|
        assert blob.persisted?
        assert blob.service.exist?(blob.key)
      end
    end

    def assert_failed_upload_cleanup(fail_on:)
      seed_images
      before = snapshot
      assert_no_difference ['ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'] do
        track_uploads(fail_on: fail_on) do |keys|
          with_upload do |upload|
            error = assert_raises(Bible270::AvatarImages::Error) do
              Bible270::AvatarImages.update!(@reader, { display_name: 'Changed Reader' }, upload: upload)
            end
            assert_match(%r{picture could not be stored}, error.message)
          end
          assert_equal fail_on, keys.size
          assert_discarded keys
        end
      end
      assert_equal before, snapshot
    end
  end
end
