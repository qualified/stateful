require "stateful/version"
require "stateful/state_info"

module Stateful
  extend ActiveSupport::Concern
  include ActiveSupport::Callbacks

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

      options[:events] ||= []
      options[:prefix] = name == :state ? '' : "#{name}_"

      # define the method that will contain the info objects.
      # we use instance_eval here because its easier to implement the ||= {} logic this way.
      instance_eval "def #{name}_infos; @#{name}_infos ||= {}; end"

      define_method "#{name}_events" do
        options[:events]
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
        raise "transition from #{send(name)} to #{new_state} not allowed for #{name}" unless current_info.can_transition_to?(new_state)
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

        callbacks = ["#{name}_change".to_sym]
        callbacks << options[:event] if options[:event]
        run_callbacks *callbacks do
          __send__("#{name}=", new_state)
          block.call if block

          ## if a specific persist method value was provided
          if options.has_key?(:persist_method)
            # call the method if one was provided
            __send__(options[:persist_method]) if options[:persist_method]
          # if no persist method option was provided than use the defaults
          else
            method = persist_methods.find {|m| respond_to?(m)}
            __send__(method) if method
          end
        end
        true
      end

      protected "change_#{name}"
      protected "change_#{name}!"
      private :_change_state

      define_method "can_transition_to_#{name}?" do |new_state|
        __send__("#{name}_info").can_transition_to?(new_state)
      end

      # init and configure state info
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
      events = (["#{name}_change".to_sym] + options[:events])
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