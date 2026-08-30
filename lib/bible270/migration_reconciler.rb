# frozen_string_literal: true

module Bible270
  # Repairs schema_migrations after a database is copied without matching migration
  # bookkeeping. A migration is safe to mark only when every table, column and
  # current index it contributes is already present.
  class MigrationReconciler
    Status = Struct.new(:migration, :missing, keyword_init: true) do
      def complete? = missing.empty?
    end

    CHECKS = {
      'CreateBible270Readers' => :check_readers,
      'CreateBible270Checkoffs' => :check_checkoffs,
      'CreateBible270Comments' => :check_comments,
      'CreateBible270SignInTokens' => :check_sign_in_tokens,
      'AddNamesToBible270Readers' => :check_names,
      'AddApprovalToBible270Comments' => :check_approval,
      'CreateBible270Settings' => :check_settings,
      'AddBibleVersionToBible270Readers' => :check_bible_version,
      'AddPartToBible270Checkoffs' => :check_checkoff_parts,
      'AddRememberTokenToBible270Readers' => :check_remember_token,
      'AddMentionNoticesToBible270Readers' => :check_mention_notices,
      'AddParentToBible270Comments' => :check_comment_parent,
      'CreateBible270Likes' => :check_likes,
      'AddBlueLetterBibleToBible270Readers' => :check_blue_letter_bible,
      'AddPassageSourceToBible270Readers' => :check_passage_source,
      'AddDailyRemindersToBible270Readers' => :check_daily_reminders,
      'AddReflectionsSeenAtToBible270Readers' => :check_reflections_seen_at,
      'AddAllCommentNoticesToBible270Readers' => :check_all_comment_notices,
      'ChangePassageSourceDefaultToBibleCom' => :check_passage_source_default,
      'CreateActiveStorageTables' => :check_active_storage
    }.freeze

    def self.for_current_database
      context = ActiveRecord::MigrationContext.new(ActiveRecord::Migrator.migrations_paths)
      new(connection: ActiveRecord::Base.connection, migration_context: context)
    end

    def initialize(connection:, migration_context:)
      @connection = connection
      @migration_context = migration_context
    end

    def statuses
      applied = migration_context.get_all_versions.map(&:to_i)
      migration_context.migrations.filter_map do |migration|
        check = CHECKS[migration.name]
        next unless check
        next if applied.include?(migration.version.to_i)

        Status.new(migration: migration, missing: public_send(check))
      end
    end

    def mark_applied!(status)
      raise ArgumentError, "#{status.migration.name} is not reflected in the schema" unless status.complete?

      migration_context.schema_migration.create_version(status.migration.version.to_s)
    end

    def check_readers
      table_missing(
        :bible270_readers,
        columns: %i[id display_name email avatar_url provider uid owner_type owner_id started_on created_at updated_at],
        indexes: [
          { columns: %i[owner_type owner_id] },
          { columns: %i[provider uid], unique: true }
        ]
      )
    end

    def check_checkoffs
      table_missing(
        :bible270_checkoffs,
        columns: %i[id reader_id day track created_at updated_at],
        indexes: [{ columns: %i[reader_id] }, { columns: %i[day] }],
        foreign_keys: [{ column: :reader_id, to_table: :bible270_readers }]
      )
    end

    def check_comments
      table_missing(
        :bible270_comments,
        columns: %i[id reader_id day track body created_at updated_at],
        indexes: [{ columns: %i[reader_id] }, { columns: %i[day created_at] }],
        foreign_keys: [{ column: :reader_id, to_table: :bible270_readers }]
      )
    end

    def check_sign_in_tokens
      table_missing(
        :bible270_sign_in_tokens,
        columns: %i[id email token_digest display_name expires_at consumed_at created_at updated_at],
        indexes: [
          { columns: %i[token_digest], unique: true },
          { columns: %i[email created_at] }
        ]
      )
    end

    def check_names
      table_missing(
        :bible270_readers,
        columns: %i[first_name last_name],
        indexes: [{ columns: %i[last_name first_name] }]
      ) + table_missing(:bible270_sign_in_tokens, columns: %i[first_name last_name])
    end

    def check_approval
      table_missing(
        :bible270_comments,
        columns: %i[approved moderated_at],
        indexes: [{ columns: %i[approved day] }]
      )
    end

    def check_settings
      table_missing(
        :bible270_settings,
        columns: %i[id key value created_at updated_at],
        indexes: [{ columns: %i[key], unique: true }]
      )
    end

    def check_bible_version
      table_missing(:bible270_readers, columns: %i[bible_version])
    end

    def check_checkoff_parts
      table_missing(
        :bible270_checkoffs,
        columns: %i[part],
        indexes: [{ columns: %i[reader_id day track part], unique: true }]
      )
    end

    def check_remember_token
      table_missing(
        :bible270_readers,
        columns: %i[remember_token],
        indexes: [{ columns: %i[remember_token] }]
      )
    end

    def check_mention_notices
      table_missing(:bible270_readers, columns: %i[notify_on_mention])
    end

    def check_comment_parent
      table_missing(
        :bible270_comments,
        columns: %i[parent_id],
        indexes: [{ columns: %i[parent_id] }],
        foreign_keys: [{ column: :parent_id, to_table: :bible270_comments }]
      )
    end

    def check_likes
      table_missing(
        :bible270_likes,
        columns: %i[id reader_id comment_id created_at updated_at],
        indexes: [
          { columns: %i[reader_id comment_id], unique: true },
          { columns: %i[comment_id] }
        ],
        foreign_keys: [
          { column: :reader_id, to_table: :bible270_readers },
          { column: :comment_id, to_table: :bible270_comments }
        ]
      )
    end

    def check_blue_letter_bible
      return [] if connection.column_exists?(:bible270_readers, :passage_source)

      table_missing(:bible270_readers, columns: %i[blue_letter_bible])
    end

    def check_passage_source
      table_missing(:bible270_readers, columns: %i[passage_source])
    end

    def check_daily_reminders
      table_missing(
        :bible270_readers,
        columns: %i[daily_reminders daily_reminder_time last_daily_reminder_sent_on]
      )
    end

    def check_reflections_seen_at
      table_missing(:bible270_readers, columns: %i[reflections_seen_at])
    end

    def check_all_comment_notices
      table_missing(:bible270_readers, columns: %i[notify_on_all_comments])
    end

    def check_passage_source_default
      missing = table_missing(:bible270_readers, columns: %i[passage_source])
      return missing if missing.any?

      column = connection.columns(:bible270_readers).find { |candidate| candidate.name == 'passage_source' }
      column&.default == 'bible_com' ? [] : ['column bible270_readers.passage_source default bible_com']
    end

    # The Bible270 installer can install Active Storage for reader avatars. A
    # copied database can therefore have the same timestamp mismatch for Rails'
    # generated Active Storage migration as it has for the engine migrations.
    def check_active_storage
      table_missing(
        :active_storage_blobs,
        columns: %i[id key filename content_type metadata service_name byte_size checksum created_at],
        indexes: [{ columns: %i[key], unique: true }]
      ) + table_missing(
        :active_storage_attachments,
        columns: %i[id name record_type record_id blob_id created_at],
        indexes: [
          { columns: %i[blob_id] },
          { columns: %i[record_type record_id name blob_id], unique: true }
        ],
        foreign_keys: [{ column: :blob_id, to_table: :active_storage_blobs }]
      ) + table_missing(
        :active_storage_variant_records,
        columns: %i[id blob_id variation_digest],
        indexes: [{ columns: %i[blob_id variation_digest], unique: true }],
        foreign_keys: [{ column: :blob_id, to_table: :active_storage_blobs }]
      )
    end

  private

    attr_reader :connection, :migration_context

    def table_missing(table, columns:, indexes: [], foreign_keys: [])
      return ["table #{table}"] unless connection.data_source_exists?(table)

      missing_columns(table, columns) +
        missing_indexes(table, indexes) +
        missing_foreign_keys(table, foreign_keys)
    end

    def missing_columns(table, expected_columns)
      existing = connection.columns(table).map { |column| column.name.to_s }
      expected_columns.filter_map do |column|
        "column #{table}.#{column}" unless existing.include?(column.to_s)
      end
    end

    def missing_indexes(table, expected_indexes)
      existing = connection.indexes(table)
      expected_indexes.filter_map do |expected|
        columns = expected.fetch(:columns).map(&:to_s)
        next if existing.any? { |index| matching_index?(index, columns, expected) }

        qualifier = expected[:unique] ? 'unique index' : 'index'
        "#{qualifier} #{table}(#{columns.join(', ')})"
      end
    end

    def matching_index?(index, columns, expected)
      index.columns == columns && (!expected.key?(:unique) || index.unique == expected[:unique])
    end

    def missing_foreign_keys(table, expected_foreign_keys)
      existing = connection.foreign_keys(table)
      expected_foreign_keys.filter_map do |expected|
        next if existing.any? { |foreign_key| matching_foreign_key?(foreign_key, expected) }

        "foreign key #{table}.#{expected[:column]} -> #{expected[:to_table]}"
      end
    end

    def matching_foreign_key?(foreign_key, expected)
      foreign_key.column.to_s == expected.fetch(:column).to_s &&
        foreign_key.to_table.to_s == expected.fetch(:to_table).to_s
    end
  end
end
