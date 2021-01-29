# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::Admin::SubscriptionOrdersController, type: :request do
  extend Spree::TestingSupport::AuthorizationHelpers::Request
  stub_authorization!

  describe 'GET :index' do
    subject do
      get spree.admin_subscription_subscription_orders_path(subscription)
      response
    end

    let(:subscription) { create :subscription, :actionable }

    it { is_expected.to be_successful }
  end
end
