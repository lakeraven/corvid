# frozen_string_literal: true

class CreateCmsFeeScheduleReleases < ActiveRecord::Migration[8.1]
  def change
    create_table :corvid_cms_fee_schedule_releases do |t|
      t.integer :year, null: false
      t.string :cms_release_tag, null: false
      t.string :source_checksum_sha256, null: false
      t.string :parser_version, null: false
      t.datetime :ingested_at, null: false
      t.integer :row_count, null: false, default: 0

      t.timestamps
    end

    add_index :corvid_cms_fee_schedule_releases, :year, unique: true
  end
end
