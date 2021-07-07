module Stateful
  # TODO: Test this code with ActiveRecord as it should in theory work just fine, with exception to maybe the scopes
  module MongoidIntegration
    extend ActiveSupport::Concern

    protected

    def process_state_transition_from_changes(field, event)
      changes = self.changes[field.to_s]
      if changes
        process_state_transition(field, event, changes.first, changes.last)
      end
    end

    module ClassMethods
      protected

      def define_state_attribute(options)
        name = options[:name].to_sym

        field(name, type: defined?(StringifiedSymbol) ? StringifiedSymbol : Symbol, default: options[:default]).tap do
          values_method_name = "#{options[:name]}_values"
          values = __send__("#{options[:name]}_infos").keys

          define_singleton_method(values_method_name) do
            values
          end

          validates_inclusion_of name,
                                 in: values,
                                 message:  options.has_key?(:message) ? options[:message] : "has invalid value",
                                 allow_nil: !!options[:allow_nil],
                                 # prevents validation from being called if the state field is redefined in a subclass
                                 if: Proc.new { |_| values == self.class.__send__(values_method_name) }

          __send__("#{options[:name]}_infos").values.each do |info|
            # configure scopes to query the attribute value
            if info.name != :nil
              states = info.collect_child_states
              prefix = options[:prefix]

              scope_name = "#{options[:prefix]}#{info.name}"

              # common state name that we can't use without a prefix
              scope_name = "#{options[:name]}_new" if scope_name == 'new'

              if states.length == 1
                scope scope_name, -> { where(name => states.first) }
              else
                scope scope_name, -> { where(name.in => states) }
              end
            end

            # add tracked fields for this state
            if info.tracked
              field("#{info.name}_at", type: Time)
              belongs_to("#{info.name}_by", class_name: 'User', optional: true) if defined?(User) && User.respond_to?(:current)
              field("#{info.name}_value", type: defined?(StringifiedSymbol) ? StringifiedSymbol : Symbol) if info.is_group?
            end
          end

          # provide a previous_state helper since mongoid provides the state_change method for us
          define_method "previous_#{options[:name]}" do
            changes = __send__("#{options[:name]}_change")
            changes.first if changes and changes.any?
          end

          define_method "previous_#{options[:name]}_info" do
            state = __send__("previous_#{options[:name]}")
            self.class.__send__("#{options[:name]}_infos")[state]
          end

          validate do
            process_state_transition_from_changes(options[:name], :validate)
          end

          before_save do
            process_state_transition_from_changes(options[:name], :before_save)
          end

          after_save do
            process_state_transition_from_changes(options[:name], :after_save)
          end

          before_validation do
            process_state_transition_from_changes(options[:name], :before_validation)
          end

          after_validation do
            process_state_transition_from_changes(options[:name], :after_validation)
          end
        end
      end
    end
  end
end