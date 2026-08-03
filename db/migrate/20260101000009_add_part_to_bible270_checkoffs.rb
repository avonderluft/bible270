# frozen_string_literal: true

class AddPartToBible270Checkoffs < ActiveRecord::Migration[7.0]
  # An Old Testament reading is usually several whole chapters, and readers get
  # through them one at a time, so each chapter becomes a separately tickable
  # part. Part 0 is the first chapter of that day's reading.
  def up
    add_column :bible270_checkoffs, :part, :integer, null: false, default: 0

    old_index = 'idx_b270_checkoffs_unique'
    remove_index :bible270_checkoffs, name: old_index if index_name_exists?(:bible270_checkoffs, old_index)
    add_index :bible270_checkoffs, %i[reader_id day track part], unique: true,
                                   name: 'idx_b270_checkoffs_part_unique'

    expand_existing_checkoffs
  end

  def down
    # Collapse back: a track counts as read if any of its chapters were.
    execute <<~SQL.squish
      DELETE FROM bible270_checkoffs
      WHERE id NOT IN (
        SELECT MIN(id) FROM bible270_checkoffs GROUP BY reader_id, day, track
      )
    SQL

    remove_index :bible270_checkoffs, name: 'idx_b270_checkoffs_part_unique'
    add_index :bible270_checkoffs, %i[reader_id day track], unique: true,
                                   name: 'idx_b270_checkoffs_unique'
    remove_column :bible270_checkoffs, :part
  end

private

  # Before this migration one row meant "the whole reading is done". Leaving
  # those rows at part 0 would silently demote a finished multi-chapter day to
  # one chapter of it, so each is expanded into a row per chapter.
  def expand_existing_checkoffs
    rows = select_all(<<~SQL.squish).to_a
      SELECT id, reader_id, day, track FROM bible270_checkoffs WHERE part = 0
    SQL
    return if rows.empty?

    now = Time.current
    additions = rows.flat_map do |row|
      count = Bible270::Plan.part_count(row['day'].to_i, row['track'])
      next [] if count <= 1

      (1...count).map do |part|
        { reader_id: row['reader_id'], day: row['day'], track: row['track'],
          part: part, created_at: now, updated_at: now }
      end
    end
    return if additions.empty?

    say "expanding #{rows.size} check-offs into #{rows.size + additions.size} chapter parts", true
    Bible270::Checkoff.insert_all(additions)
  end
end
