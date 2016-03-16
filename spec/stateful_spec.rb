require 'spec_helper'
require './lib/stateful'

class Kata
  include Stateful

  attr_accessor :approved_by, :ready_score, :published_at, :state_changes, :times_pending, :published_by, :old_state

  def initialize
    @ready_score = 0
    @state_changes = 0
    @times_pending = 0
    @published_by
  end

  stateful  default: :draft,
            events: {
                publish: :beta,
                approve: :approved,
                unpublish: :draft,
                retire: :retired
            },
            track: [:published, :draft],
            states: {
                :draft => :beta,
                published: {
                    beta: {
                        :needs_feedback => [:draft, :needs_approval],
                        :needs_approval => [:draft, :approved, :retired]
                    },
                    :approved => :retired
                },
                :retired => nil
            }

  stateful :merge_status, default: :na, events: [:merge, :approve_merge, :reject_merge], states: {
      na: :pending,
      pending: [:approved, :rejected],
      approved: nil,
      rejected: :pending
  }

  after_state_change do |doc|
    doc.state_changes += 1
  end



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

  state_event :publish do |published_by|
    transition_to_state(enough_votes_for_approval? ? :needs_approval : :needs_feedback) do
      @published_at = Time.now
      @published_by = published_by
    end
  end

  after_publish do
    @times_pending += 1
  end

  def unpublish
    change_state(:draft, :unpublish) do |old_state|
      @old_state = old_state
    end
  end

  def approve(approved_by)
    change_state(:approved, :approve) do
      @approved_by = approved_by
    end
  end

  def retire
    change_state(:retired, :retire)
  end

  def enough_votes_for_approval?
    ready_score >= 10
  end
end

class SubKata < Kata

end

describe Kata do
  let(:kata) {SubKata.new}

  it 'should support state_infos' do
    expect(Kata.state_infos).not_to be_nil
    expect(Kata.merge_status_infos).not_to be_nil
  end

  it 'should support default state' do
    expect(kata.state).to eq(:draft)
    expect(kata.merge_status).to eq(:na)
  end

  it 'should support state_info' do
    expect(kata.state_info).not_to be_nil
    expect(kata.state_info.name).to eq(:draft)
    expect(kata.state_info.tracked).to eq(true)

    # custom names
    expect(kata.merge_status_info).not_to be_nil
    expect(kata.merge_status_info.name).to eq(:na)
  end

  it 'should support simple boolean helper methods' do
    expect(kata.draft?).to be_truthy
    expect(kata.published?).to be_falsey
    kata.state = :needs_feedback
    expect(kata.published?).to be_truthy

    # custom state names
    expect(kata.merge_status_na?).to be_truthy
    expect(kata.merge_status_approved?).to be_falsey
    kata.merge_status = :approved
    expect(kata.merge_status_approved?).to be_truthy
  end

  context 'change_state' do
    it 'should raise error when an invalid transition state is provided' do
      expect{kata.send(:change_state!, :retired)}.to raise_error
      expect{kata.send(:change_merge_status!, :approved)}.to raise_error
    end

    it 'should raise error when a group state is provided' do
      expect{kata.send(:change_state!, :beta)}.to raise_error
    end

    it 'should return false when state is the same' do
      expect(kata.send(:change_state, :draft)).to be_falsey
    end

    it 'should support state_valid?' do
      expect(kata.state_valid?).to be_truthy
      expect(kata.merge_status_valid?).to be_truthy
    end

    it 'should change the state when a proper state is provided' do
      expect(kata.send(:change_state, :needs_feedback)).to be_truthy
      expect(kata.state).to eq(:needs_feedback)
      expect(kata.send(:change_state, :needs_approval)).to be_truthy
      expect(kata.state).to eq(:needs_approval)
      expect(kata.send(:change_state, :draft)).to be_truthy
      expect(kata.state).to eq(:draft)
      expect(kata.send(:change_state, :needs_approval)).to be_truthy
      expect(kata.send(:change_state, :approved)).to be_truthy
      expect(kata.state).to eq(:approved)

      # custom
      expect(kata.send(:change_merge_status, :approved)).to be_falsey
      expect(kata.send(:change_merge_status, :pending)).to be_truthy
      expect(kata.merge_status).to eq(:pending)
    end

    it 'should support calling passed blocks when state is valid' do
      expect(kata.published_at).to be_nil
      kata.publish!
      expect(kata.published_at).not_to be_nil
    end

    it 'should support passing old_state to change_state blocks' do
      kata.publish!
      expect(kata.old_state).to be_nil
      kata.unpublish
      expect(kata.old_state).to eq :needs_feedback
    end

    # pending 'should support passing in parameters to state_event defined methods' do
    #   expect(kata.published_by).to be_nil
    #   kata.publish
    #   expect(kata.published_by).to eq('test')
    #   expect(kata.published?).to be_truthy
    # end

    it 'should support ingoring passed blocked when state is not valid' do
      kata.approve('test')
      expect(kata.approved?).to be_falsey
      expect(kata.approved_by).to be_nil
    end

    it 'should support after callbacks methods' do
      kata.publish
      expect(kata.state_changes).to eq(1)
      expect(kata.times_pending).to eq(1)
    end

    it 'should support can_transition_to_state?' do
      expect(kata.can_transition_to_state?(:needs_feedback)).to be_truthy
      expect(kata.can_transition_to_state?(:approved)).to be_falsey

      # custom states
      expect(kata.can_transition_to_merge_status?(:pending)).to be_truthy
      expect(kata.can_transition_to_merge_status?(:approved)).to be_falsey
    end

    describe '#state_allowable_events' do
      it 'should handle single allowed events' do
        expect(kata.state_allowable_events).to eq [:publish]
      end

      it 'should handle multiple allowed events' do
        kata.state = :needs_approval
        expect(kata.state_allowable_events).to eq [:approve, :unpublish, :retire]
      end
    end
  end

  describe Stateful::StateInfo do
    it 'should support is?' do
      expect(Kata.state_infos[:draft].is?(:draft)).to be_truthy
      expect(Kata.state_infos[:needs_feedback].is?(:published)).to be_truthy
      expect(Kata.state_infos[:needs_feedback].is?(:beta)).to be_truthy
      expect(Kata.state_infos[:approved].is?(:published)).to be_truthy
      expect(Kata.state_infos[:approved].is?(:beta)).to be_falsey
      expect(Kata.state_infos[:retired].is?(:beta)).to be_falsey

      # custom
      expect(Kata.merge_status_infos[:na].is?(:na)).to be_truthy
    end

    it 'should support tracked states' do
      expect(Kata.state_infos[:draft].tracked).to be_truthy
      expect(Kata.state_infos[:beta].tracked).to be_truthy
      expect(Kata.state_infos[:approved].tracked).to be_truthy
      expect(Kata.state_infos[:needs_approval].tracked).to be_falsey
      expect(Kata.state_infos[:retired].tracked).to be_falsey
    end

    it 'should support expanded to transitions' do
      expect(Kata.state_infos[:draft].to_transitions).to eq([:needs_feedback, :needs_approval])
      expect(Kata.state_infos[:needs_approval].to_transitions).to eq([:draft, :approved, :retired])

      expect(Kata.state_infos[:retired].to_transitions).to be_empty
    end

    it 'should support can_transition_to?' do
      expect(Kata.state_infos[:draft].can_transition_to?(:needs_feedback)).to be_truthy
      expect(Kata.state_infos[:draft].can_transition_to?(:approved)).to be_falsey

      expect(Kata.merge_status_infos[:na].can_transition_to?(:pending)).to be_truthy
    end
  end
end