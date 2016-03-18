require 'spec_helper'
require './lib/stateful'
require 'mongoid'
require 'mongoid/document'


class Project
  include Mongoid::Document
  include Stateful

  stateful default: :draft,
           events: [:publish, :approve, :retire],
           states: {
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
    post_persist
    true
  end
end

class SubProject < Project
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

# define an example object that uses a more free form style for setting updates
# via validations and #before_transition_to
class FreeFormExample
  include Mongoid::Document
  include Stateful

  stateful default: :draft,
           validate: true,
           track: [:published, :inactive],
           states: {
            :nil => [:draft, :published, :archived],
            :draft => :*,
            :published => :*,
            inactive: {
              :archived => :draft
            },
            :non_initial => :*,
            :failed => nil
          }

  field :published_at, type: Time
  field :prevent_unarchive, type: Boolean
  field :was_drafted, type: Boolean, default: false

  attr_reader :validate_called, :published_from_draft
  attr_accessor :after_publish_callback, :star_saved, :publish_saved

  when_transition
      .from(:*)
        .to(:*)
          .after_save do
            self.star_saved = true
          end
        .to(:failed)
          .protect { raise "not allowed" }
      .from(:draft)
        .to(:published)
          .before_save { self.published_at = Time.now }
          .after_save do
            self.publish_saved = true
            @published_from_draft = true
            # our ghetto hook for testing event firing behavior
            after_publish_callback.call if after_publish_callback
          end
      .from(:published)
        .to(:draft)
          .before_save { self.published_at = nil }
      .from(nil)
        .to(:draft)
          .before_save { self.was_drafted = true }
      .from(:archived)
        .to(:published)
          .forbid_if { true }

  validate_transition_from(:archived).to(:*) do
    if prevent_unarchive
      errors[:state] << "unarchiving has been disabled"
    end
    @validate_called = 1
  end

  # fake saving since we dont have an actual database to persist to
  def save
    if valid?
      run_callbacks(:save) do
        @persisted = true
      end

      post_persist

      true
    else
      false
    end
  end

  def new_record?
    !@persisted
  end
end

class SubExample < FreeFormExample
  validate_transition_from(:inactive).to(:*) do
    @validate_called += 1
  end
end

describe Stateful::MongoidIntegration do
  let(:project) {Project.new}
  let(:example) { FreeFormExample.new }
  let(:sub_example) { SubExample.new }

  it 'should support creating a state field' do
    expect(Project.fields.keys.include?('state')).to be_truthy
  end

  it 'should support callbacks' do
    project.publish
  end

  it 'should support nil transition checks' do
    example.state = :non_initial
    expect(example.save).to be false
  end

  describe '::from_transitions' do
    it 'should set the proper configuration' do
      transitions = FreeFormExample.from_transitions
      expect(transitions[:state][:before_save][:draft][:published].first).to be_a Proc
      expect(transitions[:state][:validate][:archived][:published].first).to be_a Proc
    end
  end

  describe '::all_from_transitions' do
    it 'should inherit from the chain' do
      expect(FreeFormExample.all_from_transitions.size).to eq 1
      expect(SubExample.all_from_transitions.size).to eq 2
      expect(SubExample.all_from_transitions[0]).to be_a Hash
      expect(SubExample.all_from_transitions[1]).to be_a Hash
    end
  end

  describe 'transition DSL' do
    before { example.save }

    context 'forbid_if' do
      it 'should mark the record as invalid' do
        sub_example.state = :archived
        sub_example.save
        sub_example.state = :published
        expect(sub_example.valid?).to be false
      end
    end


    context 'nil from transitions' do
      it 'should support use them when defined' do
        sub_example.save
        expect(sub_example.was_drafted).to be true
      end

      it 'should ignore them when not relevant' do
        sub_example.state = :archived
        sub_example.save
        expect(sub_example.was_drafted).to be false
      end
    end

    it 'should inherit from parent if available' do
      sub_example.state = :archived
      sub_example.save
      sub_example.state = :draft
      sub_example.valid?
      expect(sub_example.validate_called).to eq 2
    end

    it 'should call before transitions' do
      example.state = :published
      example.save
      expect(example.published_at).to_not be_nil
    end

    it 'should handle star + specific transitions' do
      example.state = :published
      example.save
      expect(example.star_saved).to be true
      expect(example.publish_saved).to be true
    end

    # it 'should call after transitions' do
    #   example.state = :published
    #   example.save
    #   expect(example.published_from_draft).to be true
    # end

    it 'should run validations' do
      example.state = :archived
      example.save
      example.state = :draft
      expect(example).to be_valid

      example.prevent_unarchive = true
      expect(example).to_not be_valid
    end

    it 'should only allow persistance callbacks to be triggered once per object lifecycle' do
      example.after_publish_callback = -> { example.save }
      example.state = :published
      expect { example.save }.to_not raise_error
    end

    describe '#protect' do
      it 'should raise if called outside of an unprotected block' do
        example.state = :failed
        expect{example.save}.to raise_error
      end

      it 'should not raise if called inside of an unprotected block' do
        example.unprotected do
          example.state = :failed
          expect(example.save).to eq true
        end
      end
    end
  end

  describe ':* transitions' do
    it 'should allow a transition to anything if :* is used' do
      expect(example.can_transition_to_state?(:archived)).to eq true
    end

    it 'should still forbid normal transitions' do
      example.state = :archived
      expect(example.can_transition_to_state?(:published)).to eq false
    end
  end

  describe 'validations' do
    it 'should support validating state enum values' do
      expect(project.state).to eq(:draft)
      expect(project.merge_status).to eq(:na)
      expect(project.valid?).to be_truthy
      project.state = :invalid
      expect(project.valid?).to be_falsey
    end

    context 'validate: true' do
      before do
        example.state = :archived
        example.save
      end

      it 'should be invalid if state change is invalid' do
        example.state = :published
        expect(example).to_not be_valid
      end

      it 'should be valid if state change is valid' do
        example.state = :draft
        expect(example).to be_valid
      end
    end
  end

  it 'should allow states to be set manually' do
    project.state = :approved
    expect(project.valid?).to be_truthy
  end

  it 'should support state boolean helpers' do
    expect(project.draft?).to be_truthy
    expect(project.beta?).to be_falsey
    project.state = :needs_testing
    expect(project.beta?).to be_truthy
  end

  it 'should support can_transition_to?' do
    expect(project.can_transition_to_state?(:needs_testing)).to be_truthy
    expect(project.can_transition_to_state?(:retired)).to be_falsey
  end

  describe 'tracking states' do
    context 'parent states' do
      before do
        example.state = :archived
        example.save
      end

      it 'should create mongoid fields' do
        expect(example).to respond_to(:inactive_at)
        expect(example).to respond_to(:inactive_value)
      end

      it 'should track changes to parent states' do
        expect(example.inactive_value).to eq :archived
        expect(example.inactive_at).to_not be_nil
      end
    end

    context 'child states' do
      before do
        example.state = :published
        example.save
      end

      it 'should create mongoid fields' do
        expect(example).to respond_to(:published_at)
      end

      it 'should track the time' do
        expect(example.published_at).to_not be_nil
      end

      it 'should not track value' do
        expect(example).to_not respond_to(:published_value)
      end
    end
  end


  it 'should create scopes for each state and virtual state' do
    expect(Project.beta.selector).to eq({"state" => {"$in" => [:needs_testing, :needs_approval]}})
    expect(Project.not.beta.selector).to eq({"state"=>{"$not"=>{"$in"=>[:needs_testing, :needs_approval]}}})
    expect(Project.draft.selector).to eq({"state" => :draft})
    expect(Project.not.draft.selector).to eq({"state"=>{"$ne"=>:draft}})
  end

  it 'should create prefixed scopes for each state and virtual state of custom state fields' do
    expect(Project.merge_status_pending.selector).to eq({"merge_status" => :pending})
  end

  it 'should support previous_state' do
    expect(project.previous_state).to be_nil
    # cant test after creation right now until mongoid is configured correctly
  end

  describe '#change_state' do
    context 'when state is invalid' do
      it 'should fail' do
        expect(project.send(:change_state, :retired)).to be_falsey
      end

    end

    context 'when state is valid' do
      it 'should pass' do
        project.stub(:persist_state).and_return(true)
        expect(project.send(:change_state, :needs_testing)).to be_truthy
      end

      it 'should call block even if persist fails' do
        project.stub(:persist_state).and_return(false)
        called = false
        project.send(:change_state, :needs_testing) do
          called = true
        end

        expect(called).to be_truthy
      end
    end
  end

  describe 'Subclass Overrides' do
    let(:project) { SubProject.new }

    it 'should have a valid :extra state' do
      project.state = :extra
      expect(project).to be_valid
    end

    it 'should have a invalid :retired state' do
      project.state = :retired
      expect(project).to be_invalid
    end
  end
end