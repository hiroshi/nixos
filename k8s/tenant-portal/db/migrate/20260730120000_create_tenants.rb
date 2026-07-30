class CreateTenants < ActiveRecord::Migration[8.1]
  def change
    create_table :tenants do |t|
      t.string :name, null: false
      t.string :status, null: false, default: "provisioning"
      t.text :last_error

      t.timestamps
    end

    add_index :tenants, :name, unique: true
  end
end
