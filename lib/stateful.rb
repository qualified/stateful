require "stateful/version"
require "stateful/state_info"

module Stateful
  extend ActiveSupport::Concern
  include ActiveSupport::Callbacks

  included do
    if defined?(Mongoid)
      require 'mongoid/document'
      include Stateful::Mongoid if included_modules.include?(::Mongoid::Document)
    end
  end

  module ClassMethods
    def state_infos
      @state_infos ||= {}
    end

    def stateful(options)
      options[:events] ||= []

      define_method 'state_events' do
        options[:events]
      end

      define_method 'state_info' do
        self.class.state_infos[self.state]
      end

      define_method 'state_valid?' do
        self.class.state_infos.keys.include?(state)
      end

      define_method 'change_state' do |new_state, options = {}, &block|
        return false if new_state == state
        return false unless state_info.can_transition_to?(new_state)

        # convert shortcut event name to options hash
        options = {event: options} if options.is_a? Symbol
        options[:persist_methods] = [:persist_state, :save]
        _change_state(new_state, options, &block)
      end

      define_method 'change_state!' do |new_state, options = {}, &block|
        return false if new_state == state
        raise "transition from #{state} to #{new_state} not allowed" unless state_info.can_transition_to?(new_state)

        # convert shortcut event name to options hash
        options = {event: options} if options.is_a? Symbol
        options[:persist_methods] = [:persist_state!, :save!]
        _change_state(new_state, options, &block)
      end

      define_method '_change_state' do |new_state, options, &block|
        if block and block.call == false
          false
        else
          callbacks = [:state_change]
          callbacks << options[:event] if options[:event]
          run_callbacks *callbacks do
            self.state = new_state
            if options[:persist_methods]
              method = options[:persist_methods].find {|m| respond_to?(m)}
              __send__(method) if method
            end
            if respond_to?(:persist_state)
              persist_state
            elsif respond_to?(:save!)
              save!
            end
          end
          true
        end
      end

      private :_change_state


      define_method 'can_transition_to?' do |new_state|
        state_info.can_transition_to?(new_state)
      end



      # init and configure state info
      init_state_info(options[:states])
      state_infos.values.each do |info|
        info.expand_to_transitions

        define_method "#{info.name}?" do
          info.is?(self.state)
        end
      end

      # define the event callbacks
      define_callbacks *([:state_change] + options[:events])

      define_state_attribute(options)
    end

    protected
    def define_state_attribute(options)
      define_method 'state' do
        instance_variable_get(:@state) || options[:default]
      end

      define_method 'state=' do |val|
        instance_variable_set(:@state, val)
      end
    end

    private


    def init_state_info(values, parent = nil)
      values.each do |name, config|

        info = state_infos[name] = Stateful::StateInfo.new(self, parent, name, config)
        init_state_info(config, info) if info.is_group?
      end
    end
  end
end

require 'stateful/mongoid' if defined?(Mongoid)