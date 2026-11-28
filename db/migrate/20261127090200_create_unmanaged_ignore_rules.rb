class CreateUnmanagedIgnoreRules < ActiveRecord::Migration[8.1]
  def change
    create_table :unmanaged_ignore_rules do |t|
      t.references :environment, null: false, foreign_key: { on_delete: :cascade }
      t.string :source
      t.string :field, null: false, default: "identifier"
      t.string :match_type, null: false, default: "glob"
      t.string :pattern, null: false
      t.string :note
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
  end
end
