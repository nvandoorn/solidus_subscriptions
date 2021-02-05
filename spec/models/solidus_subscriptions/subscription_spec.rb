require 'spec_helper'

RSpec.describe SolidusSubscriptions::Subscription, type: :model do
  it { is_expected.to validate_presence_of :user }
  it { is_expected.to validate_presence_of :skip_count }
  it { is_expected.to validate_presence_of :successive_skip_count }
  it { is_expected.to validate_numericality_of(:skip_count).is_greater_than_or_equal_to(0) }
  it { is_expected.to validate_numericality_of(:successive_skip_count).is_greater_than_or_equal_to(0) }

  it {
    expect(subject).to validate_inclusion_of(:currency).
      in_array(::Money::Currency.all.map(&:iso_code)).
      with_message('is not a valid currency code')
  }

  it { is_expected.to accept_nested_attributes_for(:line_items) }

  describe 'creating a subscription' do
    it 'tracks the creation' do
      stub_const('Spree::Event', class_spy(Spree::Event))

      subscription = create(:subscription)

      expect(Spree::Event).to have_received(:fire).with(
        'solidus_subscriptions.subscription_created',
        subscription: subscription,
      )
    end

    it 'generates a guest token' do
      subscription = create(:subscription)

      expect(subscription.guest_token).to be_present
    end
  end

  describe 'updating a subscription' do
    it 'tracks interval changes' do
      stub_const('Spree::Event', class_spy(Spree::Event))
      subscription = create(:subscription)

      subscription.update!(interval_length: subscription.interval_length + 1)

      expect(Spree::Event).to have_received(:fire).with(
        'solidus_subscriptions.subscription_frequency_changed',
        subscription: subscription,
      )
    end

    it 'tracks shipping address changes' do
      stub_const('Spree::Event', class_spy(Spree::Event))
      subscription = create(:subscription)

      subscription.update!(shipping_address: create(:address))

      expect(Spree::Event).to have_received(:fire).with(
        'solidus_subscriptions.subscription_shipping_address_changed',
        subscription: subscription,
      )
    end

    it 'tracks billing address changes' do
      stub_const('Spree::Event', class_spy(Spree::Event))
      subscription = create(:subscription)

      subscription.update!(billing_address: create(:address))

      expect(Spree::Event).to have_received(:fire).with(
        'solidus_subscriptions.subscription_billing_address_changed',
        subscription: subscription,
      )
    end

    it 'tracks payment method changes' do
      stub_const('Spree::Event', class_spy(Spree::Event))

      subscription = create(:subscription)
      subscription.update!(payment_source: create(:credit_card))

      expect(Spree::Event).to have_received(:fire).with(
        'solidus_subscriptions.subscription_payment_method_changed',
        subscription: subscription,
      )
    end
  end

  describe '#cancel' do
    subject { subscription.cancel }

    let(:subscription) do
      create :subscription, :with_line_item, actionable_date: actionable_date
    end

    around { |e| Timecop.freeze { e.run } }

    before do
      allow(SolidusSubscriptions.configuration).to receive(:minimum_cancellation_notice) { minimum_cancellation_notice }
    end

    context 'the subscription can be canceled' do
      let(:actionable_date) { 1.month.from_now }
      let(:minimum_cancellation_notice) { 1.day }

      it 'is canceled' do
        subject
        expect(subscription).to be_canceled
      end

      it 'creates a subscription_canceled event' do
        subject
        expect(subscription.events.last).to have_attributes(event_type: 'subscription_canceled')
      end
    end

    context 'the subscription cannot be canceled' do
      let(:actionable_date) { Date.current }
      let(:minimum_cancellation_notice) { 1.day }

      it 'is pending cancelation' do
        subject
        expect(subscription).to be_pending_cancellation
      end

      it 'creates a subscription_canceled event' do
        subject
        expect(subscription.events.last).to have_attributes(event_type: 'subscription_canceled')
      end
    end

    context 'when the minimum cancellation date is 0.days' do
      let(:actionable_date) { Date.current }
      let(:minimum_cancellation_notice) { 0.days }

      it 'is canceled' do
        subject
        expect(subscription).to be_canceled
      end
    end
  end

  describe '#skip' do
    subject { subscription.skip&.to_date }

    let(:total_skips) { 0 }
    let(:successive_skips) { 0 }
    let(:expected_date) { 2.months.from_now.to_date }

    let(:subscription) do
      create(
        :subscription,
        :with_line_item,
        skip_count: total_skips,
        successive_skip_count: successive_skips
      )
    end

    before { stub_config(maximum_total_skips: 1) }

    context 'when the successive skips have been exceeded' do
      let(:successive_skips) { 1 }

      it { is_expected.to be_falsy }

      it 'adds errors to the subscription' do
        subject
        expect(subscription.errors[:successive_skip_count]).not_to be_empty
      end

      it 'does not create an event' do
        expect { subject }.not_to change(subscription.events, :count)
      end
    end

    context 'when the total skips have been exceeded' do
      let(:total_skips) { 1 }

      it { is_expected.to be_falsy }

      it 'adds errors to the subscription' do
        subject
        expect(subscription.errors[:skip_count]).not_to be_empty
      end

      it 'does not create an event' do
        expect { subject }.not_to change(subscription.events, :count)
      end
    end

    context 'when the subscription can be skipped' do
      it { is_expected.to eq expected_date }

      it 'creates a subscription_skipped event' do
        subject
        expect(subscription.events.last).to have_attributes(event_type: 'subscription_skipped')
      end
    end
  end

  describe '#deactivate' do
    subject { subscription.deactivate }

    let(:attributes) { {} }
    let(:subscription) do
      create :subscription, :actionable, :with_line_item, attributes do |s|
        s.installments = build_list(:installment, 2)
      end
    end

    context 'the subscription can be deactivated' do
      let(:attributes) do
        { end_date: Date.current.ago(2.days) }
      end

      it 'is inactive' do
        subject
        expect(subscription).to be_inactive
      end

      it 'creates a subscription_deactivated event' do
        subject
        expect(subscription.events.last).to have_attributes(event_type: 'subscription_ended')
      end
    end

    context 'the subscription cannot be deactivated' do
      it { is_expected.to be_falsy }

      it 'does not create an event' do
        expect { subject }.not_to change(subscription.events, :count)
      end
    end
  end

  describe '#activate' do
    context 'when the subscription can be activated' do
      it 'activates the subscription' do
        subscription = create(:subscription,
          actionable_date: Time.zone.today,
          end_date: Time.zone.yesterday,)
        subscription.deactivate!

        subscription.activate

        expect(subscription.state).to eq('active')
      end

      it 'creates a subscription_activated event' do
        subscription = create(:subscription,
          actionable_date: Time.zone.today,
          end_date: Time.zone.yesterday,)
        subscription.deactivate!

        subscription.activate

        expect(subscription.events.last).to have_attributes(event_type: 'subscription_activated')
      end
    end

    context 'the subscription cannot be activated' do
      it 'returns false' do
        subscription = create(:subscription, actionable_date: Time.zone.today)

        expect(subscription.activate).to eq(false)
      end

      it 'does not create an event' do
        subscription = create(:subscription, actionable_date: Time.zone.today)

        expect {
          subscription.activate
        }.not_to change(subscription.events, :count)
      end
    end
  end

  describe '#next_actionable_date' do
    subject { subscription.next_actionable_date }

    context "when the subscription is active" do
      let(:expected_date) { Date.current + subscription.interval }
      let(:subscription) do
        build_stubbed(
          :subscription,
          :with_line_item,
          actionable_date: Date.current
        )
      end

      it { is_expected.to eq expected_date }
    end

    context "when the subscription is not active" do
      let(:subscription) { build_stubbed :subscription, :with_line_item, state: :canceled }

      it { is_expected.to be_nil }
    end
  end

  describe '#advance_actionable_date' do
    subject { subscription.advance_actionable_date }

    let(:expected_date) { Date.current + subscription.interval }
    let(:subscription) do
      build(
        :subscription,
        :with_line_item,
        actionable_date: Date.current
      )
    end

    it { is_expected.to eq expected_date }

    it 'updates the subscription with the new actionable date' do
      subject
      expect(subscription.reload).to have_attributes(
        actionable_date: expected_date
      )
    end
  end

  describe ".actionable" do
    subject { described_class.actionable }

    let!(:past_subscription) { create :subscription, actionable_date: 2.days.ago }
    let!(:future_subscription) { create :subscription, actionable_date: 1.month.from_now }
    let!(:inactive_subscription) { create :subscription, state: "inactive", actionable_date: 7.days.ago }
    let!(:canceled_subscription) { create :subscription, state: "canceled", actionable_date: 4.days.ago }

    it "returns subscriptions that have an actionable date in the past" do
      expect(subject).to include past_subscription
    end

    it "does not include future subscriptions" do
      expect(subject).not_to include future_subscription
    end

    it "does not include inactive subscriptions" do
      expect(subject).not_to include inactive_subscription
    end

    it "does not include canceled subscriptions" do
      expect(subject).not_to include canceled_subscription
    end
  end

  describe '#processing_state' do
    subject { subscription.processing_state }

    context 'when the subscription has never been processed' do
      let(:subscription) { build_stubbed :subscription }

      it { is_expected.to eq 'pending' }
    end

    context 'when the last processing attempt failed' do
      let(:subscription) do
        create(
          :subscription,
          installments: create_list(:installment, 1, :failed)
        )
      end

      it { is_expected.to eq 'failed' }
    end

    context 'when the last processing attempt succeeded' do
      let(:order) { create :completed_order_with_totals }

      let(:subscription) do
        create(
          :subscription,
          installments: create_list(
            :installment,
            1,
            :success,
            details: build_list(:installment_detail, 1, order: order, success: true)
          )
        )
      end

      it { is_expected.to eq 'success' }
    end
  end

  describe '.ransackable_scopes' do
    subject { described_class.ransackable_scopes }

    it { is_expected.to match_array [:in_processing_state] }
  end

  describe '.in_processing_state' do
    subject { described_class.in_processing_state(state) }

    let!(:new_subs) { create_list :subscription, 2 }
    let!(:failed_subs) { create_list(:installment, 2, :failed).map(&:subscription) }
    let!(:success_subs) { create_list(:installment, 2, :success).map(&:subscription) }

    context 'successfull subscriptions' do
      let(:state) { :success }

      it { is_expected.to match_array success_subs }
    end

    context 'failed subscriptions' do
      let(:state) { :failed }

      it { is_expected.to match_array failed_subs }
    end

    context 'new subscriptions' do
      let(:state) { :pending }

      it { is_expected.to match_array new_subs }
    end

    context 'unknown state' do
      let(:state) { :foo }

      it 'raises an error' do
        expect { subject }.to raise_error ArgumentError, /state must be one of/
      end
    end
  end

  describe '.processing_states' do
    subject { described_class.processing_states }

    it { is_expected.to match_array [:pending, :success, :failed] }
  end

  describe '#payment_source_to_use' do
    context 'when the subscription has a payment method without source' do
      it 'returns nil' do
        payment_method = create(:check_payment_method)

        subscription = create(:subscription, payment_method: payment_method)

        expect(subscription.payment_source_to_use).to eq(nil)
      end
    end

    context 'when the subscription has a payment method with a source' do
      it 'returns the source on the subscription' do
        user = create(:user)
        payment_method = create(:credit_card_payment_method)
        payment_source = create(:credit_card,
          payment_method: payment_method,
          gateway_customer_profile_id: 'BGS-123',
          user: user,)

        subscription = create(:subscription,
          user: user,
          payment_method: payment_method,
          payment_source: payment_source,)

        expect(subscription.payment_source_to_use).to eq(payment_source)
      end
    end

    context 'when the subscription has no payment method' do
      it "returns the default source from the user's wallet_payment_source" do
        user = create(:user)
        payment_source = create(:credit_card, gateway_customer_profile_id: 'BGS-123', user: user)
        wallet_payment_source = user.wallet.add(payment_source)
        user.wallet.default_wallet_payment_source = wallet_payment_source

        subscription = create(:subscription, user: user)

        expect(subscription.payment_source_to_use).to eq(payment_source)
      end
    end
  end

  describe '#payment_method_to_use' do
    context 'when the subscription has a payment method without source' do
      it 'returns the payment method on the subscription' do
        payment_method = create(:check_payment_method)
        subscription = create(:subscription, payment_method: payment_method)

        expect(subscription.payment_method_to_use).to eq(payment_method)
      end
    end

    context 'when the subscription has a payment method with a source' do
      it 'returns the payment method on the subscription' do
        user = create(:user)
        payment_method = create(:credit_card_payment_method)
        payment_source = create(:credit_card,
          payment_method: payment_method,
          gateway_customer_profile_id: 'BGS-123',
          user: user,)

        subscription = create(:subscription,
          user: user,
          payment_method: payment_method,
          payment_source: payment_source,)

        expect(subscription.payment_method_to_use).to eq(payment_method)
      end
    end

    context 'when the subscription has no payment method' do
      it "returns the method from the default source in the user's wallet_payment_source" do
        user = create(:user)
        payment_source = create(:credit_card, gateway_customer_profile_id: 'BGS-123', user: user)
        wallet_payment_source = user.wallet.add(payment_source)
        user.wallet.default_wallet_payment_source = wallet_payment_source

        subscription = create(:subscription, user: user)

        expect(subscription.payment_method_to_use).to eq(payment_source.payment_method)
      end
    end
  end

  describe '#billing_address_to_use' do
    context 'when the subscription has a billing address' do
      it 'returns the billing address on the subscription' do
        billing_address = create(:bill_address)

        subscription = create(:subscription, billing_address: billing_address)

        expect(subscription.billing_address_to_use).to eq(billing_address)
      end
    end

    context 'when the subscription has no billing address' do
      it 'returns the billing address on the user' do
        user = create(:user)
        billing_address = create(:bill_address)
        user.bill_address = billing_address

        subscription = create(:subscription, user: user)

        expect(subscription.billing_address_to_use).to eq(billing_address)
      end
    end
  end

  describe '#shipping_address_to_use' do
    context 'when the subscription has a shipping address' do
      it 'returns the shipping address on the subscription' do
        shipping_address = create(:ship_address)

        subscription = create(:subscription, shipping_address: shipping_address)

        expect(subscription.shipping_address_to_use).to eq(shipping_address)
      end
    end

    context 'when the subscription has no shipping address' do
      it 'returns the shipping address on the user' do
        user = create(:user)
        shipping_address = create(:ship_address)
        user.ship_address = shipping_address

        subscription = create(:subscription, user: user)

        expect(subscription.shipping_address_to_use).to eq(shipping_address)
      end
    end
  end

  describe "#update_actionable_date_if_interval_changed" do
    context "with installments" do
      context "when the last installment date would cause the interval to be in the past" do
        it "sets the actionable_date to the current day" do
          subscription = create(:subscription, actionable_date: Time.zone.parse('2016-08-22'))
          create(:installment, subscription: subscription, created_at: Time.zone.parse('2016-07-22'))

          subscription.update!(interval_length: 1, interval_units: 'month')

          expect(subscription.actionable_date).to eq(Time.zone.today)
        end
      end

      context "when the last installment date would cause the interval to be in the future" do
        it "sets the actionable_date to an interval from the last installment" do
          subscription = create(:subscription, actionable_date: Time.zone.parse('2016-08-22'))
          create(:installment, subscription: subscription, created_at: 4.days.ago)

          subscription.update!(interval_length: 1, interval_units: 'month')

          expect(subscription.actionable_date).to eq((4.days.ago + 1.month).to_date)
        end
      end
    end

    context "when there are no installments" do
      context "when the subscription creation date would cause the interval to be in the past" do
        it "sets the actionable_date to the current day" do
          subscription = create(:subscription, created_at: Time.zone.parse('2016-08-22'))

          subscription.update!(interval_length: 1, interval_units: 'month')

          expect(subscription.actionable_date).to eq(Time.zone.today)
        end
      end

      context "when the subscription creation date would cause the interval to be in the future" do
        it "sets the actionable_date to one interval past the subscription creation date" do
          subscription = create(:subscription, created_at: 4.days.ago)

          subscription.update!(interval_length: 1, interval_units: 'month')

          expect(subscription.actionable_date).to eq((4.days.ago + 1.month).to_date)
        end
      end
    end
  end

  describe '#failing_since' do
    context 'when the subscription is not failing' do
      it 'returns nil' do
        subscription = create(:subscription, installments: [
          create(:installment, details: [
            create(:installment_detail, success: false, created_at: '2020-11-11'),
            create(:installment_detail, success: false, created_at: '2020-11-12'),
            create(:installment_detail, success: true, created_at: '2020-11-13'),
          ]),
          create(:installment, details: [
            create(:installment_detail, success: false, created_at: '2020-11-24'),
            create(:installment_detail, success: true, created_at: '2020-11-25'),
          ]),
        ])

        expect(subscription.failing_since).to eq(nil)
      end
    end

    context 'when the subscription is failing with a previous success' do
      it 'returns the date of the first failure' do
        subscription = create(:subscription, installments: [
          create(:installment, details: [
            create(:installment_detail, success: false, created_at: '2020-11-11'),
            create(:installment_detail, success: false, created_at: '2020-11-12'),
            create(:installment_detail, success: true, created_at: '2020-11-13'),
          ]),
          create(:installment, details: [
            create(:installment_detail, success: false, created_at: '2020-11-24'),
            create(:installment_detail, success: false, created_at: '2020-11-25'),
          ]),
          create(:installment, details: [
            create(:installment_detail, success: false, created_at: '2020-11-26'),
            create(:installment_detail, success: false, created_at: '2020-11-27'),
          ]),
        ])

        expect(subscription.failing_since).to eq(Time.zone.parse('2020-11-24'))
      end
    end

    context 'when the subscription is failing with no previous success' do
      it 'returns the date of the first failure' do
        subscription = create(:subscription, installments: [
          create(:installment, details: [
            create(:installment_detail, success: false, created_at: '2020-11-11'),
            create(:installment_detail, success: false, created_at: '2020-11-12'),
            create(:installment_detail, success: false, created_at: '2020-11-13'),
          ]),
          create(:installment, details: [
            create(:installment_detail, success: false, created_at: '2020-11-24'),
            create(:installment_detail, success: false, created_at: '2020-11-25'),
          ]),
          create(:installment, details: [
            create(:installment_detail, success: false, created_at: '2020-11-26'),
            create(:installment_detail, success: false, created_at: '2020-11-27'),
          ]),
        ])

        expect(subscription.failing_since).to eq(Time.zone.parse('2020-11-11'))
      end
    end
  end

  describe '#maximum_reprocessing_time_reached?' do
    context 'when maximum_reprocessing_time is not configured' do
      it 'returns false' do
        stub_config(maximum_reprocessing_time: 5.days)
        subscription = create(:subscription)

        expect(subscription.maximum_reprocessing_time_reached?).to eq(false)
      end
    end

    context 'when maximum_reprocessing_time is configured' do
      context 'when the subscription has been failing for too long' do
        it 'returns true' do
          stub_config(maximum_reprocessing_time: 15.days)

          subscription = create(:subscription, installments: [
            create(:installment, details: [
              create(:installment_detail, success: false, created_at: 20.days.ago),
              create(:installment_detail, success: false, created_at: 19.days.ago),
              create(:installment_detail, success: true, created_at: 18.days.ago),
            ]),
            create(:installment, details: [
              create(:installment_detail, success: false, created_at: 17.days.ago),
              create(:installment_detail, success: false, created_at: 16.days.ago),
            ]),
            create(:installment, details: [
              create(:installment_detail, success: false, created_at: 15.days.ago),
              create(:installment_detail, success: false, created_at: 14.days.ago),
            ]),
          ])

          expect(subscription.maximum_reprocessing_time_reached?).to eq(true)
        end
      end

      context 'when the subscription has not been failing for too long' do
        it 'returns false' do
          stub_config(maximum_reprocessing_time: 15.days)

          subscription = create(:subscription, installments: [
            create(:installment, details: [
              create(:installment_detail, success: false, created_at: 15.days.ago),
              create(:installment_detail, success: false, created_at: 14.days.ago),
              create(:installment_detail, success: true, created_at: 13.days.ago),
            ]),
            create(:installment, details: [
              create(:installment_detail, success: false, created_at: 12.days.ago),
              create(:installment_detail, success: false, created_at: 11.days.ago),
            ]),
            create(:installment, details: [
              create(:installment_detail, success: false, created_at: 10.days.ago),
              create(:installment_detail, success: false, created_at: 9.days.ago),
            ]),
          ])

          expect(subscription.maximum_reprocessing_time_reached?).to eq(false)
        end
      end

      context 'when the subscription is not failing' do
        it 'returns false' do
          stub_config(maximum_reprocessing_time: 2.days)

          subscription = create(:subscription, installments: [
            create(:installment, details: [
              create(:installment_detail, success: false, created_at: 15.days.ago),
              create(:installment_detail, success: false, created_at: 14.days.ago),
              create(:installment_detail, success: true, created_at: 13.days.ago),
            ]),
            create(:installment, details: [
              create(:installment_detail, success: false, created_at: 12.days.ago),
              create(:installment_detail, success: false, created_at: 11.days.ago),
            ]),
            create(:installment, details: [
              create(:installment_detail, success: false, created_at: 10.days.ago),
              create(:installment_detail, success: true, created_at: 9.days.ago),
            ]),
          ])

          expect(subscription.maximum_reprocessing_time_reached?).to eq(false)
        end
      end
    end
  end
end
