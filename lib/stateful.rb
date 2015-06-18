require "stateful/version"
require "stateful/state_info"

module Stateful
  extend ActiveSupport::Concern
  include ActiveSupport::Callbacks

  class StateChangeError < RuntimeError
  end

  protected

  def process_state_transition(field, event, from, to)
    return unless self.class.all_from_transitions.any?

    self.class.all_from_transitions.each do |transitions|
      config = transitions[field]
      config = config[event] if config
      config = config[from] if config
      procs = config[to] if config
      if procs
        procs.each do |proc|
          self.instance_eval(&proc)
        end
      end
    end
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

      # handle different types of inclusion/inheritance
      klass = self.class == Class ? self : self.class

      # define the method that will contain the info objects.
      # we use instance_eval here because its easier to implement the ||= {} logic this way.
      instance_eval "def #{name}_infos; @#{name}_infos ||= {}; end"

      define_singleton_method "#{name}_infos" do
        klass.instance_eval "@#{name}_infos ||= {}"
      end

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

      define_method "#{name}_info" do |state = __send__(name)|
        self.class.__send__("#{name}_infos")[state]
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

      ## transition validations support

      if options[:validate]
        validate_method_name = "validate_#{name}_transition"
        validate(validate_method_name, unless: :new_record?)

        # define a validation method that checks if the updated state is allowed to be transitioned into
        define_method(validate_method_name) do
          changes = self.changes[name.to_s]
          if changes
            old_state = __send__("#{name}_info", changes.first)
            unless old_state.can_transition_to?(changes.last)
              errors[name] << "#{changes.last} is not a valid transition state from #{changes.first}"
            end
          end
        end

        # mark the validates method as protected
        protected validate_method_name
      end

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

      infos = __send__("#{name}_infos")
      infos.values.each do |info|
        info.expand_to_transitions(infos)

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

    # recursivly collects the from_transitions configuration for all super classes as well as this class.
    # this method is used by the process_state_transition and is stored in reverse order so that the ancestors are
    # iterated first
    def all_from_transitions
      @all_from_transitions ||= begin
        all = (from_transitions ? [from_transitions] : [])

        if superclass.respond_to?(:all_from_transitions)
          all += superclass.all_from_transitions
        end

        all.reverse
      end
    end

    # the stored configuration for the before/after/validate_transition_from family of callback methods
    def from_transitions
      @from_transitions ||= {}
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

    def before_transition_from(field, state = nil)
      transition_from(:before, field, state)
    end

    def after_transition_from(field, state = nil)
      transition_from(:after, field, state)
    end

    def validate_transition_from(field, state = nil)
      transition_from(:validate, field, state)
    end

    def transition_from(event, field, from_state)
      if from_state.nil?
        from_state = field
        field = :state
      end

      FromTransition.new do |to_states, &block|
        config = from_transitions[field] ||= {}
        config = config[event] ||= {}
        config = config[from_state] ||= {}

        # need to expand the any selector
        if to_states == [:*]
          to_states = __send__("#{field}_infos").keys - [from_state]
        end

        to_states.each do |to_state|
          config[to_state] ||= []
          config[to_state] << block
        end
      end
    end

    def when_transition_from(field, from_state = nil)
      WhenTransition.new do |event, to_states, &block|
        transition_from(event, field, from_state).to(*to_states, &block)
      end
    end

    class WhenTransition
      def initialize(&block)
        @block = block
      end

      def to(*states)
        @states = states
        self
      end

      def before(&block)
        @block.call(:before, @states, &block)
        self
      end

      def after(&block)
        @block.call(:after, @states, &block)
        self
      end

      def validate(&block)
        @block.call(:validate, @states, &block)
        self
      end
    end

    class FromTransition
      def initialize(&block)
        @block = block
      end

      def to(*states, &block)
        @block.call(states, &block)
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