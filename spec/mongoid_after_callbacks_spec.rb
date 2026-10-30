require 'spec_helper'
require './lib/stateful'
require 'mongoid'
require 'mongoid/document'

Mongoid.configure do |config|
  config.clients.default = { hosts: [ENV['MONGO_HOST'] || 'localhost:27017'], database: 'test' }
end

# Uses a real MongoDB so that Mongoid's own dirty tracking inside after_* callbacks is exercised.
class AfterCallbackExample
  include Mongoid::Document
  include Stateful

  stateful default: :draft, states: { nil: [:draft, :published], draft: :published, published: :draft }

  attr_reader :log

  def log
    @log ||= []
  end

  when_transition
    .from(:nil).to(:draft)
      .after_save { log << [:after_save, :nil, :draft] }
      .after_update { log << [:after_update, :nil, :draft] }
    .from(:draft).to(:published)
      .after_save { log << [:after_save, :draft, :published] }
      .after_update { log << [:after_update, :draft, :published] }
    .from(:published).to(:draft)
      .after_save { log << [:after_save, :published, :draft] }
end

describe 'after_save/after_update transitions against a real MongoDB' do
  before { AfterCallbackExample.delete_all }

  it 'fires after_save on create (nil -> default)' do
    doc = AfterCallbackExample.create!
    expect(doc.log).to include([:after_save, :nil, :draft])
  end

  it 'does not fire after_update on create' do
    doc = AfterCallbackExample.create!
    expect(doc.log).not_to include([:after_update, :nil, :draft])
  end

  it 'fires after_save on update' do
    doc = AfterCallbackExample.create!
    doc.log.clear
    doc.state = :published
    doc.save!
    expect(doc.log).to include([:after_save, :draft, :published])
  end

  it 'fires after_update on update' do
    doc = AfterCallbackExample.create!
    doc.log.clear
    doc.state = :published
    doc.save!
    expect(doc.log).to include([:after_update, :draft, :published])
  end

  it 'fires each callback exactly once per save' do
    doc = AfterCallbackExample.create!
    doc.log.clear
    doc.state = :published
    doc.save!
    expect(doc.log.count([:after_save, :draft, :published])).to eq(1)
  end

  it 'fires again for a subsequent distinct transition on the same instance' do
    doc = AfterCallbackExample.create!
    doc.update!(state: :published)
    doc.log.clear
    doc.update!(state: :draft)
    expect(doc.log).to eq([[:after_save, :published, :draft]])
  end

  it 'does not fire when the state is unchanged' do
    doc = AfterCallbackExample.create!
    doc.log.clear
    doc.save!
    expect(doc.log).to be_empty
  end
end
