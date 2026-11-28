class CreateUnmanagedResources < ActiveRecord::Migration[8.1]
  def change
    create_table :unmanaged_resources do |t|
      t.references :drift_check, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :identifier, null: false
      t.string :resource_type
      t.string :name
      t.string :scope
      t.string :location
      t.jsonb :metadata, null: false, default: {}
      t.boolean :ignored, null: false, default: false
      t.string :ignore_reason
      t.timestamps
    end
    add_index :unmanaged_resources, [ :drift_check_id, :ignored ]
  end
end
