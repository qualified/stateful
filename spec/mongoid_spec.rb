require 'spec_helper'
require './lib/stateful'
require 'mongoid'
require 'mongoid/document'


class Kata
  include Mongoid::Document
  include Stateful

  stateful default: :draft, events: [:publish, :approve, :retire], states: {
    :draft => :beta,
    beta: {
      :needs_testing => :needs_approval,
      :needs_approval => :approved
    },
    :approved => :retired,
    :retired => nil
  }

  stateful :merge_status, default: :na, events: [:merge, :approve_merge, :reject_merge], states: {
    na: :pending,
    pending: [:approved, :rejected],
    approved: nil,
    rejected: :pending
  }

  def publish
    change_state(:needs_testing, :publish)
  end

  def persist_state
    true
  end
end

class SubKata < Kata
  stateful default: :draft, events: [:publish, :approve, :retire], states: {
      :draft => :beta,
      beta: {
          :needs_testing => :needs_approval,
          :needs_approval => :approved
      },
      :approved => :extra,
      :extra => nil
  }
end

describe Stateful::MongoidIntegration do
  let(:kata) {Kata.new}

  it 'should support creating a state field' do
    expect(Kata.fields.keys.include?('state')).to be_truthy
  end

  it 'should support callbacks' do
    kata.publish
  end

  it 'should support validating state values' do
    expect(kata.state).to eq(:draft)
    expect(kata.merge_status).to eq(:na)
    expect(kata.valid?).to be_truthy
    kata.state = :invalid
    expect(kata.valid?).to be_falsey
  end

  it 'should allow states to be set manually' do
    kata.state = :approved
    expect(kata.valid?).to be_truthy
  end

  it 'should support state boolean helpers' do
    expect(kata.draft?).to be_truthy
    expect(kata.beta?).to be_falsey
    kata.state = :needs_testing
    expect(kata.beta?).to be_truthy
  end

  it 'should support can_transition_to?' do
    expect(kata.can_transition_to_state?(:needs_testing)).to be_truthy
    expect(kata.can_transition_to_state?(:retired)).to be_falsey
  end

  it 'should create scopes for each state and virtual state' do
    expect(Kata.beta.selector).to eq({"state" => {"$in" => [:needs_testing, :needs_approval]}})
    expect(Kata.draft.selector).to eq({"state" => :draft})
  end

  it 'should create prefixed scopes for each state and virtual state of custom state fields' do
    expect(Kata.merge_status_pending.selector).to eq({"merge_status" => :pending})
  end

  it 'should support previous_state' do
    expect(kata.previous_state).to be_nil
    # cant test after creation right now until mongoid is configured correctly
  end

  describe '#change_state' do
    context 'when state is invalid' do
      it 'should fail' do
        expect(kata.send(:change_state, :retired)).to be_falsey
      end

    end

    context 'when state is valid' do
      it 'should pass' do
        kata.stub(:persist_state).and_return(true)
        expect(kata.send(:change_state, :needs_testing)).to be_truthy
      end

      it 'should call block even if persist fails' do
        kata.stub(:persist_state).and_return(false)
        called = false
        kata.send(:change_state, :needs_testing) do
          called = true
        end

        expect(called).to be_truthy
      end
    end
  end

  describe 'Subclass Overrides' do
    let(:kata) { SubKata.new }

    it 'should have a valid :extra state' do
      kata.state = :extra
      expect(kata).to be_valid
    end

    it 'should have a invalid :retired state' do
      kata.state = :retired
      expect(kata).to be_valid
    end
  end
end