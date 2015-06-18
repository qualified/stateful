module Stateful
  class StateInfo
    attr_reader :parent, :children, :name, :to_transitions
    def initialize(state_class, attr_name, parent, name, config)
      raise ':new cannot be used as a state name do to naming conflicts' if name.to_s == 'new'

      @attr_name = attr_name
      @state_class = state_class
      if parent
        @parent = parent
        parent.children << self
      end

      @name = name
      @to_transitions = []

      if config.is_a?(Hash)
        @group_config = config
        @children = []
      else
        @to_transitions = config ? (config.is_a?(Array) ? config : [config]) : []
      end
    end

    def is?(state)
      !!(@name == state or (parent and parent.is?(state)))
    end

    def is_group?
      !!@group_config
    end

    def infos
      @state_class.__send__("#{@attr_name}_infos")
    end

    def can_transition_to?(state)
      state_info = infos[state]
      if is_group? or state_info.nil? or state_info.is_group?
        false
      else
        to_transitions.include?(state)
      end
    end

    def collect_child_states
      is_group? ? children.flat_map(&:collect_child_states) : [name]
    end

    def expand_to_transitions(infos)
      if to_transitions.any?
        if @to_transitions == [:*]
          @to_transitions = infos.keys - [@name]
        end

        @to_transitions = to_transitions.flat_map do |to|
          info = infos[to]

          if info.is_group?
            info.collect_child_states
          else
            [info.name]
          end
        end
      end
    end
  end
end