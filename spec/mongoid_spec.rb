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

  after_state_change do

    p self.is_a?(Kata)
  end

  def persist_state

  end
end

describe Stateful::Mongoid do
  let(:kata) {Kata.new}

  it 'should support creating a state field' do
    Kata.fields.keys.include?('state').should be_true
  end

  it 'should support callbacks' do
    kata.publish
  end

  it 'should support validating state values' do
    kata.state.should == :draft
    kata.valid?.should be_true
    kata.state = :invalid
    kata.valid?.should be_false
  end

  it 'should support state boolean helpers' do
    kata.draft?.should be_true
    kata.beta?.should be_false
    kata.state = :needs_testing
    kata.beta?.should be_true
  end

  it 'should support can_transition_to?' do
    kata.can_transition_to_state?(:needs_testing).should be_true
    kata.can_transition_to_state?(:retired).should be_false
  end

  it 'should create scopes for each state and virtual state' do
    Kata.beta.selector.should == {"state" => {"$in" => [:needs_testing, :needs_approval]}}
    Kata.draft.selector.should == {"state" => :draft}
  end


end