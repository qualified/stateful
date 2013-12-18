require "stateful/version"
require "stateful/state_info"

module Stateful
  extend ActiveSupport::Concern
  include ActiveSupport::Callbacks

  included do
    if defined?(Mongoid)
      require 'mongoid/document'
      require 'stateful/mongoid'
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
        _change_state(new_state, options, [:persist_state, :save], &block)
      end

      define_method 'change_state!' do |new_state, options = {}, &block|
        raise "transition from #{state} to #{new_state} not allowed" unless state_info.can_transition_to?(new_state)
        _change_state(new_state, options, [:persist_state!, :save!], &block)
      end

      define_method '_change_state' do |new_state, options, persist_methods, &block|
        # convert shortcut event name to options hash
        options = {event: options} if options.is_a? Symbol

        # do a little magic and infer the event name from the method name used to call change_state
        # TODO: decide if this is too magical, for now it has been commented out.
        #unless options[:event]
        #  calling_method = caller[1][/`.*'/][1..-2].gsub('!', '').to_sym
        #  options[:event] = calling_method if state_events.include? calling_method
        #end

        if block and block.call == false
          false
        else
          callbacks = [:state_change]
          callbacks << options[:event] if options[:event]
          run_callbacks *callbacks do
            self.state = new_state

            ## if a specific persist method value was provided
            #if options.has_key?(:persist_method)
            #  # call the method if one was provided
            #  __send__(options[:persist_method]) if options[:persist_method]
            ## if no persist method option was provided than use the defaults
            #else
              method = persist_methods.find {|m| respond_to?(m)}
              __send__(method) if method
            #end
          end
          true
        end
      end

      protected :change_state
      protected :change_state!
      private :_change_state

      define_method 'can_transition_to?' do |new_state|
        state_info.can_transition_to?(new_state)
      end

      # init and configure state info
      init_state_info(options[:states])
      state_infos.values.each do |info|
        info.expand_to_transitions

        define_method "#{info.name}?" do
          self.state_info.is?(info.name)
        end
      end


      define_state_attribute(options)

      # define the event callbacks
      events = ([:state_change] + options[:events])
      define_callbacks *events

      # define callback helpers
      events.each do |event|
        define_singleton_method "before_#{event}" do |method = nil, &block|
          set_callback(event, :before, method ? method : block)
        end

        define_singleton_method "after_#{event}" do |method = nil, &block|
          set_callback(event, :after, method ? method : block)
        end
      end
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