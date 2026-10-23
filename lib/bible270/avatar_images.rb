# frozen_string_literal: true

require_relative 'avatar_optimizer'

module Bible270
  # Originals and their display thumbnails are separate, immutable blobs. All
  # storage work finishes before attachment changes become visible to readers.
  class AvatarImages
    class Error < StandardError; end

    class << self
      def update!(reader, attributes, upload: nil)
        raise Error, 'Picture uploads require Active Storage.' if upload && !reader.class.avatar_uploads?

        require_own_transaction!(reader) if upload

        reader.assign_attributes(attributes)
        raise ActiveRecord::RecordInvalid, reader unless reader.valid?
        return reader.save! unless upload

        blobs = []
        AvatarOptimizer.open(upload.tempfile.path, content_type: upload.content_type, byte_size: upload.size) do |output|
          # Do not let Active Storage decode the unsanitized original again in
          # an analysis job. Validation/conversion already ran through our safe
          # pipeline, and originals are retained for reprocessing, not variants.
          original = store_blob(blobs, io: upload.tempfile, filename: upload.original_filename,
                                       content_type: upload.content_type.to_s.downcase.split(';').first.to_s.strip,
                                       metadata: { 'analyzed' => true })
          thumbnail = store_thumbnail(blobs, output, original)
          pending_attributes = reader.changes.transform_values(&:last)
          reader.class.transaction do
            # Reload under the row lock: cached (even nil) attachments may have
            # changed during processing. Replacing a stale association can leave
            # multiple attachments with the same has_one_attached name.
            reader.class.lock.find(reader.id)
            reader.attachment_changes.delete('avatar')
            reader.attachment_changes.delete('avatar_thumbnail')
            reader.reload
            reader.assign_attributes(pending_attributes)
            reader.avatar = original
            reader.avatar_thumbnail = thumbnail
            reader.save!
          end
        end
      ensure
        discard_unattached(blobs)
      end

      def optimize_existing!(reader, force: false)
        return result(:skipped) unless reader.avatar_uploaded?

        require_own_transaction!(reader)
        original = reader.avatar.blob
        if !force && reader.avatar_optimized?
          return result(:skipped, original.byte_size, reader.avatar_thumbnail.blob.byte_size)
        end

        problem = Avatars.problem_with(content_type: original.content_type, byte_size: original.byte_size)
        raise AvatarOptimizer::Error, "Avatar #{problem}." if problem

        blobs = []
        thumbnail = download_original(original) do |input|
          AvatarOptimizer.open(input.path, content_type: original.content_type, byte_size: original.byte_size) do |output|
            store_thumbnail(blobs, output, original)
          end
        end
        reader.with_lock do
          unless reader.avatar_uploaded? && reader.avatar.blob.id == original.id
            return result(:changed, original.byte_size)
          end
          if !force && reader.avatar_optimized?
            return result(:skipped, original.byte_size, reader.avatar_thumbnail.blob.byte_size)
          end

          reader.avatar_thumbnail = thumbnail
          reader.save!
        end
        result(:optimized, original.byte_size, thumbnail.byte_size)
      ensure
        discard_unattached(blobs)
      end

      def remove!(reader)
        return unless reader.class.avatar_uploads?

        # Detach atomically; Active Storage purges both old blobs after commit.
        reader.with_lock do
          reader.avatar = nil
          reader.avatar_thumbnail = nil
          reader.save!
        end
      end

    private

      def require_own_transaction!(reader)
        return unless [reader.class, ActiveStorage::Blob].any? do |model|
          model.connection_pool.with_connection(&:transaction_open?)
        end

        # Files cannot roll back with an outer database transaction. Reject that
        # usage before creating blobs rather than leaking files on a later abort.
        raise Error, 'Avatar uploads and optimization must run outside an existing database transaction.'
      end

      def download_original(original, &)
        original.open(&)
      rescue AvatarOptimizer::Error, Error
        raise
      rescue StandardError => e
        Rails.logger.error("Bible270 avatar download failed (#{e.class}).")
        raise Error, 'The original picture could not be read. Check storage availability and file integrity.'
      end

      def result(status, before_bytes = 0, after_bytes = 0)
        { status: status, before_bytes: before_bytes, after_bytes: after_bytes }
      end

      def store_thumbnail(blobs, output, original)
        store_blob(blobs, io: output, filename: 'avatar.webp', content_type: 'image/webp',
                          service_name: original.service_name,
                          metadata: { 'bible270_avatar_version' => AvatarOptimizer::VERSION,
                                      'bible270_avatar_source_id' => original.id,
                                      'width' => AvatarOptimizer::SIZE, 'height' => AvatarOptimizer::SIZE,
                                      'analyzed' => true })
      end

      def store_blob(blobs, **attributes)
        attributes.fetch(:io).rewind
        # Register the blob before uploading so a partial storage failure can be
        # cleaned up too. create_and_upload! would not return that failed blob.
        blob = ActiveStorage::Blob.create_after_unfurling!(**attributes, identify: false)
        blobs << blob
        blob.upload_without_unfurling(attributes.fetch(:io))
        blob
      rescue StandardError => e
        Rails.logger.error("Bible270 avatar storage failed (#{e.class}).")
        raise Error, 'Your picture could not be stored. Please try again.'
      end

      def discard_unattached(blobs)
        Array(blobs).each do |blob|
          # An after-commit callback may raise after a successful save. Never
          # remove blobs that have already become somebody's live attachment.
          blob.with_lock do
            next if blob.attachments.exists?

            # Unlike purge, delete storage first. If deletion fails, retain the
            # unattached row (service/key) so maintenance can retry cleanup.
            blob.delete
            blob.destroy!
          end
        rescue StandardError => e
          Rails.logger.error("Bible270 unused avatar blob #{blob.id} cleanup failed (#{e.class}); retry unattached-blob cleanup.")
        end
      end
    end
  end
end
