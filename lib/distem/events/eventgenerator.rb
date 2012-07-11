require 'distem'

module Distem
  module Events

    # Class to generate events from a probabilist distribution
    class EventGenerator < Event

      def initialize(resource_desc, change_type, generator_desc, event_value = nil, value_generator = nil, date_generator = nil)

        @generator_desc = generator_desc
        @random_generators = {}
        raise "No description given for the date generator" unless @generator_desc['date']

        if change_type == 'churn'
          event_value = 'down' unless event_value
        else
          raise "No description given for the value generator" unless @generator_desc['value']
          if value_generator
            @random_generators['value'] = value_generator
          else
            @random_generators['value'] = RngStreamRandomGenerator.new
          end
          event_value = get_random_value('value')
          if change_type == 'power'
            # For this event,  non-integer values are accepted only if between 0 and 1
            event_value = event_value.round if event_value > 1
          else
            #No integer value allowed - As 0 means infinity in some cases, we only start from 1
            event_value = event_value.round
            event_value = 1 if event_value == 0
          end
        end

        super(resource_desc, change_type, event_value)

        if date_generator
          @random_generators['date'] = date_generator
        else
          @random_generators['date'] = RngStreamRandomGenerator.new
        end

      end

      def get_next_date
        return get_random_value('date')
      end

      def trigger(event_list, date)
        super
        next_event = get_next_event
        next_date = get_next_date + date
        event_list.add_event(next_date, next_event)
      end

      protected

      def get_next_event
        next_value = nil
        if @change_type == 'churn'
          next_value = (@event_value == 'up' ? 'down' : 'up')
        end
        return EventGenerator.new(@resource_desc, @change_type, @generator_desc, next_value, @random_generators['value'], @random_generators['date'])
      end

      # Get a value for the choosen generator, 'date' or 'value'
      def get_random_value(generator)
        generator_parameters = @generator_desc[generator]
        random_generator = @random_generators[generator]

        if generator_parameters['distribution'] == 'uniform'
          return generator_parameters['min'].to_f +
              (generator_parameters['max'].to_f - generator_parameters['min'].to_f) * random_generator.rand_U01

        elsif generator_parameters['distribution'] == 'exponential'
          return -Math::log(random_generator.rand_U01) / generator_parameters['rate'].to_f

        elsif generator_parameters['distribution'] == 'weibull'
          return generator_parameters['scale'] * ( (-Math::log(random_generator.rand_U01)) ** (1.0 / generator_parameters['shape'].to_f) )

        else
          raise "Probabilist distribution not supported : #{generator_parameters['distribution']}"
        end
      end

    end

  end
end