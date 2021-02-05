class AddCurrencyToSubscription < ActiveRecord::Migration[6.1]
  def change
    add_column :solidus_subscriptions_subscriptions, :currency, :string
  end
end
