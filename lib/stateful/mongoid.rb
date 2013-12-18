module Stateful
  module MongoidIntegration
    extend ActiveSupport::Concern

    module ClassMethods
      protected

      def define_state_attribute(options)
        field options[:name].to_sym, type: Symbol, default: options[:default]
        validates_inclusion_of options[:name].to_sym,
                               in: state_infos.keys,
                               message: options.has_key?(:message) ? options[:message] : "invalid options[:name] value",
                               allow_nil: !!options[:allow_nil]

        # configure scopes to query the attribute value
        __send__("#{options[:name]}_infos").values.each do |info|
          states = info.collect_child_states
          scope_name = "#{options[:prefix]}#{info.name}"
          if states.length == 1
            scope scope_name, where(options[:name] => states.first)
          else
            scope scope_name, where(options[:name].to_sym.in => states)
          end
        end
      end
    end
  end
end