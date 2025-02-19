# frozen_string_literal: true

module Karafka
  module Processing
    module Jobs
      # Type of job that we may use to run some extra handling that happens without the user
      # related lifecycle event like consumption, revocation, etc.
      class Idle < Base
        # @param executor [Karafka::Processing::Executor] executor that is suppose to run a given
        #   job on an active consumer
        # @return [Shutdown]
        def initialize(executor)
          @executor = executor
          super()
        end

        # Run the idle work via the executor
        def call
          executor.idle
        end
      end
    end
  end
end
