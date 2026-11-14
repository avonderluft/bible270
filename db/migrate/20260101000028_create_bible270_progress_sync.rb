# frozen_string_literal: true

class CreateBible270ProgressSync < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_participations, :progress_sync_generation, :integer, null: false, default: 0

    create_table :bible270_progress_sync_links do |t|
      t.references :participation, null: false,
                                   foreign_key: { to_table: :bible270_participations, on_delete: :cascade },
                                   index: { name: 'idx_b270_sync_links_participation' }
      t.integer :source_generation, null: false
      t.string :destination, null: false
      t.string :destination_url, null: false
      t.bigint :remote_reader_id, null: false
      t.bigint :remote_participation_id, null: false
      t.integer :remote_generation, null: false
      t.string :remote_name, null: false
      t.string :email, null: false
      t.string :plan_fingerprint, null: false
      t.string :state, null: false, default: 'active'
      t.datetime :last_synced_at
      t.text :last_error
      t.integer :last_added
      t.integer :last_existing
      t.timestamps
    end
    # Paused links retain their immutable target and delivery history. Explicit
    # relinking creates a new row; old outbox entries can never change recipients.
    add_index :bible270_progress_sync_links, %i[participation_id destination], unique: true,
                                                                               where: "state = 'active'", name: 'idx_b270_sync_links_active_destination'

    create_table :bible270_progress_sync_deliveries do |t|
      t.references :progress_sync_link, null: false,
                                        foreign_key: { to_table: :bible270_progress_sync_links, on_delete: :cascade },
                                        index: { name: 'idx_b270_sync_deliveries_link' }
      t.json :readings, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at, null: false
      t.datetime :locked_until
      t.string :claim_token
      t.datetime :delivered_at
      t.text :last_error
      t.timestamps
    end
    add_index :bible270_progress_sync_deliveries, %i[delivered_at next_attempt_at locked_until],
              name: 'idx_b270_sync_deliveries_due'
  end
end
