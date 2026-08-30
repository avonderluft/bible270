# frozen_string_literal: true

class ChangePassageSourceDefaultToBibleCom < ActiveRecord::Migration[7.0]
  def change
    change_column_default :bible270_readers, :passage_source,
                          from: 'bible_gateway', to: 'bible_com'
  end
end
