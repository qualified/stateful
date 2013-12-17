module Stateful
  module Mongoid
    extend ActiveSupport::Concern

    module ClassMethods
      protected

      def define_state_attribute(options)
        field :state, type: Symbol, default: options[:default]
        validates_inclusion_of :state,
                               in: state_infos.keys,
                               message: options.has_key?(:message) ? options[:message] : 'invalid state value',
                               allow_nil: !!options[:allow_nil]

        # configure scopes to query the attribute value
        state_infos.values.each do |info|
          states = info.collect_child_states
          if states.length == 1
            scope info.name, where(state: states.first)
          else
            scope info.name, where(:state.in => states)
          end
        end
      end
    end
  end
end