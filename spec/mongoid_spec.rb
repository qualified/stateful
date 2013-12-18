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
end

describe Stateful::Mongoid do
  let(:kata) {Kata.new}

  it 'should support creating a state field' do
    Kata.fields.keys.include?('state').should be_true
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
    kata.can_transition_to?(:needs_testing).should be_true
    kata.can_transition_to?(:retired).should be_false
  end

  it 'should create scopes for each state and virtual state' do
    Kata.beta.selector.should == {"state" => {"$in" => [:needs_testing, :needs_approval]}}
    Kata.draft.selector.should == {"state" => :draft}
  end
end