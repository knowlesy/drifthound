class AddSourceAndUnmanagedCountsToDriftChecks < ActiveRecord::Migration[8.1]
  def change
    add_column :drift_checks, :source, :string, null: false, default: "terraform"
    add_column :drift_checks, :unmanaged_count, :integer
    add_column :drift_checks, :unmanaged_ignored_count, :integer
    add_index :drift_checks, [ :environment_id, :source, :created_at ]
  end
end
