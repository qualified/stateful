require "stateful/version"
require "stateful/state_info"

module Stateful
  extend ActiveSupport::Concern
  include ActiveSupport::Callbacks

  class StateChangeError < RuntimeError
  end

  included do
    if defined?(Mongoid)
      require 'mongoid/document'
      require 'stateful/mongoid'
      include Stateful::MongoidIntegration if included_modules.include?(::Mongoid::Document)
    end
  end

  module ClassMethods

    def stateful(name, options = nil)
      if name.is_a?(Hash)
        options = name
        name = options[:name] || :state
      end

      options[:name] = name

      if options[:events].is_a? Array
        options[:events] = {}.tap do |hash|
          options[:events].each do |event|
            hash[event] = nil
          end
        end
      end

      options[:events] ||= {}
      options[:prefix] = name == :state ? '' : "#{name}_"

      # define the method that will contain the info objects.
      # we use instance_eval here because its easier to implement the ||= {} logic this way.
      instance_eval "def #{name}_infos; @#{name}_infos ||= {}; end"

      define_method "#{name}_events" do
        options[:events]
      end

      # returns a list of events that can be called given the current state
      define_method "#{name}_allowable_events" do
        options[:events].select do |k, v|
          fromState = __send__("#{name}_info")
          v = [v] unless v.is_a? Array
          v.all? do |v|
            toState = self.class.__send__("#{name}_infos")[v]

            # if a group state then we need to see if the current state can transition
            # to all states within the group
            if toState.is_group?
              toState.collect_child_states.all? do |state|
                fromState.can_transition_to?(state)
              end
            else
              fromState.can_transition_to?(v)
            end
          end
        end.keys
      end

      define_method "#{name}_info" do
        self.class.__send__("#{name}_infos")[__send__(name)]
      end

      define_method "#{name}_valid?" do
        self.class.__send__("#{name}_infos").keys.include?(__send__(name))
      end

      define_method "change_#{name}" do |new_state, options = {}, &block|
        return false if new_state == __send__(name)
        return false unless __send__("#{name}_info").can_transition_to?(new_state)
        __send__("_change_#{name}", new_state, options, [:persist_state, :save], &block)
      end

      define_method "change_#{name}!" do |new_state, options = {}, &block|
        current_info = __send__("#{name}_info")
        raise StateChangeError.new "transition from #{send(name)} to #{new_state} not allowed for #{name}" unless current_info.can_transition_to?(new_state)
        __send__("_change_#{name}", new_state, options, [:persist_state!, :save!], &block)
      end

      define_method "_change_#{name}" do |new_state, options, persist_methods, &block|
        # convert shortcut event name to options hash
        options = {event: options} if options.is_a? Symbol

        # do a little magic and infer the event name from the method name used to call change_state
        # TODO: decide if this is too magical, for now it has been commented out.
        #unless options[:event]
        #  calling_method = caller[1][/`.*'/][1..-2].gsub('!', '').to_sym
        #  options[:event] = calling_method if state_events.include? calling_method
        #end

        run_callbacks "#{name}_change".to_sym do

          run_callbacks (options[:event] || "#{name}_non_event_change") do
            old_state = __send__(name)
            __send__("#{name}=", new_state)
            block.call(old_state) if block

            ## if a specific persist method value was provided
            if options.has_key?(:persist_method)
              # call the method if one was provided
              __send__(options[:persist_method]) if options[:persist_method]
            # if no persist method option was provided than use the defaults
            else
              method = persist_methods.find {|m| respond_to?(m)}
              if method
                __send__(method)
              else
                true
              end
            end
          end
        end
      end

      protected "change_#{name}"
      protected "change_#{name}!"
      private :_change_state

      ## state events support:

      # provide a reader so that the current event being fired can be accessed
      attr_reader "#{name}_event".to_sym

      define_singleton_method "#{name}_event" do |event, &block|
        define_method(event) do
          instance_variable_set("@#{name}_change_method", "change_#{name}")
          instance_variable_set("@#{name}_event", event)
          begin
            result = instance_eval &block
          ensure
            instance_variable_set("@#{name}_change_method", nil)
            instance_variable_set("@#{name}_event", nil)
          end
          result
        end

        define_method("#{event}!") do
          instance_variable_set("@#{name}_change_method", "change_#{name}!")
          instance_variable_set("@#{name}_event", event)
          begin
            result = instance_eval &block
          ensure
            instance_variable_set("@#{name}_change_method", nil)
            instance_variable_set("@#{name}_event", nil)
          end
          result
        end
      end

      # define the transition_to_state method that works in conjunction with the state_event
      define_method "transition_to_#{name}" do |new_state, &block|
        event = __send__("#{name}_event")
        unless event
          raise StateChangeError.new "transition_to_#{name} can only be called while a #{name} event is being called"
        end

        method = instance_variable_get("@#{name}_change_method")
        __send__(method, new_state, event, &block)
      end

      protected "transition_to_#{name}"

      define_method "can_transition_to_#{name}?" do |new_state|
        __send__("#{name}_info").can_transition_to?(new_state)
      end

      ## init and configure state info:

      init_state_info(name, options[:states])
      __send__("#{name}_infos").values.each do |info|
        info.expand_to_transitions

        define_method "#{options[:prefix]}#{info.name}?" do
          current_info = __send__("#{name}_info")
          !!(current_info && current_info.is?(info.name))
        end
      end

      define_state_attribute(options)

      # define the event callbacks
      events = (["#{name}_change".to_sym, "#{name}_non_event_change".to_sym] + options[:events].keys)
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
      define_method options[:name] do
        instance_variable_get("@#{options[:name]}") || options[:default]
      end

      define_method "#{options[:name]}=" do |val|
        instance_variable_set("@#{options[:name]}", val)
      end
    end

    private

    def init_state_info(name, values, parent = nil)
      values.each do |state_name, config|
        info = __send__("#{name}_infos")[state_name] = Stateful::StateInfo.new(self, name, parent, state_name, config)
        init_state_info(name, config, info) if info.is_group?
      end
    end
  end
end

require 'stateful/mongoid' if defined?(Mongoid)