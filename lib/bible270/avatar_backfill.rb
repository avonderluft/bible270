# frozen_string_literal: true

module Bible270
  class AvatarBackfill
    DEFAULT_BATCH_SIZE = 100
    MAX_BATCH_SIZE = 1000

    class Error < StandardError; end

    def initialize(dry_run: false, force: false, batch_size: DEFAULT_BATCH_SIZE, output: $stdout)
      @dry_run = dry_run
      @force = force
      @batch_size = validate_batch_size(batch_size)
      @output = output
    end

    # processed counts successful optimizations, not all visited readers. Byte
    # totals cover successful/current derivatives only, never failed or raced work.
    def run
      check_storage!
      summary = { processed: 0, skipped: 0, changed: 0, failed: 0, eligible: 0,
                  original_bytes: 0, optimized_bytes: 0 }

      Reader.with_avatar.joins(:avatar_attachment).find_each(batch_size: @batch_size) do |reader|
        if @dry_run
          eligible = @force || !reader.avatar_optimized?
          summary[eligible ? :eligible : :skipped] += 1
          @output.puts "reader_id=#{reader.id} #{eligible ? 'eligible' : 'skipped'}"
        else
          process(reader, summary)
        end
      end

      if @dry_run
        @output.puts "DRY RUN: eligible=#{summary[:eligible]} skipped=#{summary[:skipped]} " \
                     'processed=0 changed=0 failed=0'
      else
        @output.puts "processed=#{summary[:processed]} skipped=#{summary[:skipped]} " \
                     "changed=#{summary[:changed]} failed=#{summary[:failed]}"
        @output.puts "Display bytes (optimized/skipped readers): original=#{summary[:original_bytes]} " \
                     "optimized=#{summary[:optimized_bytes]}. Originals retained."
      end
      summary
    end

  private

    def validate_batch_size(value)
      valid = value.is_a?(Integer) || (value.is_a?(String) && value.match?(%r{\A[0-9]+\z}))
      size = Integer(value, 10) if valid && value.is_a?(String)
      size = value if value.is_a?(Integer)
      return size if valid && size.between?(1, MAX_BATCH_SIZE)

      raise Error, "BATCH_SIZE must be a positive integer between 1 and #{MAX_BATCH_SIZE}."
    end

    def check_storage!
      return if Reader.avatar_uploads? && defined?(ActiveStorage::Blob) &&
                defined?(ActiveStorage::Attachment) && ActiveStorage::Blob.table_exists? &&
                ActiveStorage::Attachment.table_exists?

      raise Error, 'Avatar backfill requires Active Storage. Enable active_storage/engine, ' \
                   'configure a storage service, and run bin/rails active_storage:install and bin/rails db:migrate in the host app.'
    end

    def process(reader, summary)
      result = AvatarImages.optimize_existing!(reader, force: @force)
      case result.fetch(:status)
      when :optimized, :skipped
        summary[result[:status] == :optimized ? :processed : :skipped] += 1
        summary[:original_bytes] += result.fetch(:before_bytes)
        summary[:optimized_bytes] += result.fetch(:after_bytes)
      when :changed
        summary[:changed] += 1
      else
        raise Error, 'Avatar optimizer returned an unsupported status.'
      end
      @output.puts "reader_id=#{reader.id} #{result[:status]}"
    rescue AvatarOptimizer::Error
      record_failure(reader, summary, 'image processing failed; check the source image and libvips codec support')
    rescue AvatarImages::Error
      record_failure(reader, summary, 'storage failed; check storage service configuration and access')
    rescue ActiveRecord::ActiveRecordError
      record_failure(reader, summary, 'database failed; check database availability and record integrity')
    end

    def record_failure(reader, summary, reason)
      summary[:failed] += 1
      # Exception messages, causes and record inspections can expose private data.
      @output.puts "reader_id=#{reader.id} failed: #{reason}"
    end
  end
end
