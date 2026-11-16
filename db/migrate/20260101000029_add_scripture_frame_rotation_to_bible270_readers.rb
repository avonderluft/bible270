# frozen_string_literal: true

class AddScriptureFrameRotationToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_readers, :scripture_frame_rotation, :json, null: false, default: {}
  end
end
