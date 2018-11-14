require "stateful/version"
require "stateful/state_info"

module Stateful
  extend ActiveSupport::Concern
  include ActiveSupport::Callbacks

  class StateChangeError < RuntimeError
  end

  # the all when_transition.protect callbacks will be ignored if processed while inside of this block
  def unprotected(&block)
    begin
      @unprotected = true
      block.call
    ensure
      @unprotected = false
    end
  end

  def unprotected?
    @unprotected
  end

  def self.store
    store ||= defined?(RequestStore) ? RequestStore.store : Thread.current
  end

  protected

  def process_state_transition(field, event, from, to)
    return unless self.class.all_from_transitions.any?

    track_event(to) if event == :before_save

    self.class.all_from_transitions.each do |transitions|
      config = transitions[field]
      config = config[event] if config
      config = config[from] if config
      procs = config[to] if config

      if procs
        procs.each do |proc|
          self.instance_exec(from, to, &proc)
        end
      end
    end
  end

  # attempts to set fields about the state change if the state was configured to be tracked
  def track_event(to)
    info = self.class.state_infos[to]
    if info
      tracked_field = info.tracked ? info.name : tracked_parent(info)
      if tracked_field
        self["#{tracked_field}_at"] = Time.now
        self["#{tracked_field}_by_id"] = User.current.id.to_s if defined?(User) && User.respond_to?(:current) && User.current.try(:id).present?
        self["#{tracked_field}_value"] = to if self.respond_to? "#{tracked_field}_value"
      end
    end
  end

  # recursive parent search to see if any parent states are tracked
  # returns parent name if tracked, otherwise nil
  def tracked_parent(info)
    info.parent.tracked ? info.parent.name : tracked_parent(info.parent) if info.parent
  end

  included do
    if defined?(Mongoid)
      require 'mongoid/document'
      require 'stateful/mongoid'
      include Stateful::MongoidIntegration if included_modules.include?(::Mongoid::Document)
    end
  end

  module ClassMethods

    def stateful_fields
      @stateful_fields ||= {}
    end

    def stateful_tracked_fields
      @stateful_tracked_fields ||= {}
    end

    def stateful(name, options = nil)
      if name.is_a?(Hash)
        options = name
        name = options[:name] || :state
      end

      options[:name] = name

      #### initial state support
      # :nil is used to represent a new object's state and is used to handle security
      # for initial object values. It is added by default if not provided specifically
      options[:states][:nil] ||= :*
      ####

      #### events are being phased out
      if options[:events].is_a? Array
        options[:events] = {}.tap do |hash|
          options[:events].each do |event|
            hash[event] = nil
          end
        end
      end

      options[:events] ||= {}
      options[:prefix] ||= name == :state ? '' : "#{name}_"

      # handle different types of inclusion/inheritance
      klass = self.class == Class ? self : self.class

      stateful_fields[options[:name]] = options

      stateful_tracked_fields[options[:name]] = options[:track] if options[:track].present?

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
      protected "change_#{name}!"
      private "_change_#{name}"

      ## transition validations support

      if options[:validate]
        validate_method_name = "validate_#{name}_transition"
        validate(validate_method_name.to_sym)

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

      # alias :nil to nil for easier lookup
      infos[nil] = infos[:nil]

      # define the event callbacks
      events = (["#{name}_change".to_sym, "#{name}_non_event_change".to_sym] + options[:events].keys)
      define_callbacks *events.map(&:to_sym)

      # define callback helpers
      events.each do |event|
        define_singleton_method "before_#{event}" do |method = nil, &block|
          set_callback(event.to_sym, :before, method ? method : block)
        end

        define_singleton_method "after_#{event}" do |method = nil, &block|
          set_callback(event.to_sym, :after, method ? method : block)
        end
      end

      define_state_attribute(options)
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

    def before_transition_from(field, from_states = nil)
      transition_from(:before_save, field, from_states)
    end

    def after_transition_from(field, from_states = nil)
      transition_from(:after_save, field, from_states)
    end

    def validate_transition_from(field, from_states = nil)
      transition_from(:validate, field, from_states)
    end

    def transition_from(event, field, from_states)
      if from_states.nil?
        from_states = field
        field = :state
      end

      from_states = [from_states] unless from_states.is_a? Array

      # need to expand any selector. In this case we grab all of the states and then filter out later.
      from_states = expand_state_names(field, from_states)

      FromTransition.new do |to_states, &block|
        to_states = to_states.flatten # just in case an array was explictely passed in
        from_states.each do |from_state|
          config = from_transitions[field] ||= {}
          config = config[event] ||= {}
          config = config[from_state] ||= {}

          expand_state_names(field, to_states).each do |to_state|
            # need to filter since the from :* selector could result in from and to being the same
            unless to_state == from_state
              config[to_state] ||= []
              config[to_state] << block
            end
          end
        end
      end
    end

    def when_transition(field = :state)
      WhenTransition.new(field) do |event, from_states, to_states, &block|
        transition_from(event, field, from_states).to(*to_states, &block)
      end
    end

    def expand_state_names(field, states, excludes = [])
      infos = __send__("#{field}_infos")

      # map :* to all states + nil
      states = states.map do |state|
        state == :* ? [infos.keys] << nil : state
      end.flatten

      infos = states.map do |state|
        info = infos[state]
        if info
          info.collect_child_states
        else
          raise "There is no info for state #{state}"
        end
      end.flatten.uniq - excludes

      # we need to handle the special nil name
      infos.map {|info| info == :nil ? nil : info }
    end

    class WhenTransition
      def initialize(field, &block)
        @field = field
        @block = block
      end

      def from(*states)
        @from_states = states
        # force the dsl to require a follow up "to" decleration for easier readability
        @to_states = nil
        self
      end

      def to(*states)
        @to_states = states
        self
      end

      # easy way to add validation errors based off of state. If a truthy value is returned than the
      # validation error will be added to the state field. You can pass a string back to customize the
      # validation error, otherwise return true and a default error will be added.
      def forbid_if(&block)
        field = @field
        add_callback :validate do |from, to|
          result = instance_exec(from, to, &block)
          if result
            if result.is_a?(String)
              self.errors[field] << result
            else
              self.errors[field] << "Cannot transition from #{from} to #{to}"
            end
          end
        end
      end

      # this callback is ran before_save unless it is called inside of a "unprotected" block
      def protect(callback = :before_save, &block)
        add_callback(callback.to_sym) do |from, to|
          unless @unprotected
            instance_exec(from, to, &block)
          end
        end
      end

      def before_validation(&block)
        add_callback(:before_validation, &block)
      end

      def after_validation(&block)
        add_callback(:after_validation, &block)
      end

      def before_save(&block)
        add_callback(:before_save, &block)
      end

      def after_save(&block)
        add_run_once_callback(:after_save, &block)
      end

      def before(&block)
        add_callback(:before_save, &block)
      end

      def after(&block)
        add_run_once_callback(:after_save, &block)
      end

      def before_create(&block)
        add_callback(:before_create, &block)
      end

      def after_create(&block)
        add_callback(:after_create, &block)
      end

      def before_update(&block)
        add_callback(:before_update, &block)
      end

      def after_update(&block)
        add_run_once_callback(:after_update, &block)
      end

      def validate(&block)
        add_callback(:validate, &block)
      end

      # def method_missing(name, &block)
      #   run(name, &block)
      # end

      # Mongoid is stupid and still shows changes as being dirty within after callbacks.
      # This can cause logic that then tries to update the record again which can cause a cyclic loop.
      # So we only run these callbacks once per instance lifecycle, per each state transition.
      def add_run_once_callback(event, &block)
        add_callback(event.to_sym) do |from, to|
          @ran_stateful_callbacks ||= {}
          key = [from, to]
          ran_events = @ran_stateful_callbacks[key] ||= {}
          ran_blocks = ran_events[event] ||= []
          unless ran_blocks.include?(block.hash)
            ran_blocks << block.hash
            instance_exec(from, to, &block)
          end
        end
      end

      def add_callback(event, &block)
        @block.call(event, @from_states, @to_states, &block)
        self
      end
    end

    class FromTransition
      def initialize(&block)
        @block = block
      end

      def to(*states, &block)
        @block.call(states, &block)
        self
      end
    end

    private

    def init_state_info(name, values, parent = nil)
      values.each do |state_name, config|
        tracked = @stateful_tracked_fields[name].try(:include?, state_name) if @stateful_tracked_fields
        info = __send__("#{name}_infos")[state_name] = Stateful::StateInfo.new(self, name, parent, state_name, config, tracked)
        init_state_info(name, config, info) if info.is_group?
      end
    end
  end
end

require 'stateful/mongoid' if defined?(Mongoid)