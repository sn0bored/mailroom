class AddCatchAllMxHostToDomains < ActiveRecord::Migration[8.1]
  def change
    add_column :domains, :catch_all_mx_host, :string
  end
end
