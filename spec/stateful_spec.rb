require 'spec_helper'
require './lib/stateful'

class Kata
  include Stateful

  attr_accessor :approved_by, :ready_score, :published_at

  def initialize
    @ready_score = 0
  end

  stateful  default: :draft,
            events: [:publish, :unpublish, :approve, :retire],
            states: {
                :draft => :beta,
                published: {
                    beta: {
                        :needs_feedback => [:draft, :needs_approval],
                        :needs_approval => [:draft, :approved]
                    },
                    :approved => :retired
                },
                :retired => nil
            }


  def vote(ready)
    @ready_score += ready ? 1 : -1

    # votes only affect state when in beta
    if beta?
      if enough_votes_for_approval? and needs_feedback?
        change_state(:needs_approval)
      elsif not enough_votes_for_approval? and needs_approval?
        change_state(:needs_feedback)
      end
    end
  end

  def publish
    change_state(enough_votes_for_approval? ? :needs_approval : :needs_feedback) do
      @published_at = Time.now
    end
  end

  def unpublish
    change_state(:draft)
  end

  def approve(approved_by)
    change_state(:approved) do
      @approved_by = approved_by
    end
  end

  def retire
    change_state(:retire)
  end

  def enough_votes_for_approval?
    ready_score >= 10
  end
end

describe Kata do
  let(:kata) {Kata.new}

  it 'should support state_infos' do
    Kata.state_infos.should_not be_nil
  end

  it 'should support default state' do
    kata.state.should == :draft
  end

  it 'should support state_info' do
    kata.state_info.should_not be_nil
    kata.state_info.name.should == :draft
  end

  it 'should support simple boolean helper methods' do
    kata.draft?.should be_true
    kata.published?.should be_false
  end

  context 'change_state' do
    it 'should raise error when an invalid transition state is provided' do
      expect{kata.change_state(:retired)}.to raise_error
    end

    it 'should raise error when a group state is provided' do
      expect{kata.change_state(:beta)}.to raise_error
    end

    it 'should return false when state is the same' do
      kata.change_state(:draft).should be_false
    end

    it 'should support state_valid?' do
      kata.state_valid?.should be_true
    end

    it 'should change the state when a proper state is provided' do
      kata.change_state(:needs_feedback).should be_true
      kata.state.should == :needs_feedback
      kata.change_state(:needs_approval).should be_true
      kata.state.should == :needs_approval
      kata.change_state(:draft).should be_true
      kata.state.should == :draft
      kata.change_state(:needs_approval).should be_true
      kata.change_state(:approved).should be_true
      kata.state.should == :approved
    end

    it 'should support calling passed blocks when state is valid' do
      kata.published_at.should be_nil
      kata.publish
      kata.published_at.should_not be_nil
    end

    it 'should support ingoring passed blocked when state is not valid' do
      kata.approve('test')
      kata.approved?.should be_false
      kata.approved_by.should be_nil
    end
  end

  describe Stateful::StateInfo do
    it 'should support is?' do
      Kata.state_infos[:draft].is?(:draft).should be_true
      Kata.state_infos[:needs_feedback].is?(:published).should be_true
      Kata.state_infos[:needs_feedback].is?(:beta).should be_true
      Kata.state_infos[:approved].is?(:published).should be_true
      Kata.state_infos[:approved].is?(:beta).should be_false
      Kata.state_infos[:retired].is?(:beta).should be_false
    end

    it 'should support expanded to transitions' do
      Kata.state_infos[:draft].to_transitions.should == [:needs_feedback, :needs_approval]
      Kata.state_infos[:needs_approval].to_transitions.should == [:draft, :approved]

      Kata.state_infos[:retired].to_transitions.should be_empty
    end
  end
end