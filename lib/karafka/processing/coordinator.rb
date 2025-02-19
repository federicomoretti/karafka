# frozen_string_literal: true

module Karafka
  module Processing
    # Basic coordinator that allows us to provide coordination objects into consumers.
    #
    # This is a wrapping layer to simplify management of work to be handled around consumption.
    #
    # @note This coordinator needs to be thread safe. Some operations are performed only in the
    #   listener thread, but we go with thread-safe by default for all not to worry about potential
    #   future mistakes.
    class Coordinator
      attr_reader :pause_tracker, :seek_offset, :topic, :partition

      # @param topic [Karafka::Routing::Topic]
      # @param partition [Integer]
      # @param pause_tracker [Karafka::TimeTrackers::Pause] pause tracker for given topic partition
      def initialize(topic, partition, pause_tracker)
        @topic = topic
        @partition = partition
        @pause_tracker = pause_tracker
        @revoked = false
        @consumptions = {}
        @running_jobs = 0
        @manual_pause = false
        @mutex = Mutex.new
        @marked = false
        @failure = false
      end

      # Starts the coordinator for given consumption jobs
      # @param messages [Array<Karafka::Messages::Message>] batch of message for which we are
      #   going to coordinate work. Not used with regular coordinator.
      def start(messages)
        @failure = false
        @running_jobs = 0
        # We need to clear the consumption results hash here, otherwise we could end up storing
        # consumption results of consumer instances we no longer control
        @consumptions.clear

        # When starting to run, no pause is expected and no manual pause as well
        @manual_pause = false

        # We set it on the first encounter and never again, because then the offset setting
        # should be up to the consumers logic (our or the end user)
        # Seek offset needs to be always initialized as for case where manual offset management
        # is turned on, we need to have reference to the first offset even in case of running
        # multiple batches without marking any messages as consumed. Rollback needs to happen to
        # the last place we know of or the last message + 1 that was marked
        #
        # It is however worth keeping in mind, that this may need to be used with `#marked?` to
        # make sure that the first offset is an offset that has been marked.
        @seek_offset ||= messages.first.offset
      end

      # @param offset [Integer] message offset
      def seek_offset=(offset)
        synchronize do
          @marked = true
          @seek_offset = offset
        end
      end

      # Increases number of jobs that we handle with this coordinator
      def increment
        synchronize { @running_jobs += 1 }
      end

      # Decrements number of jobs we handle at the moment
      def decrement
        synchronize do
          @running_jobs -= 1

          return @running_jobs unless @running_jobs.negative?

          # This should never happen. If it does, something is heavily out of sync. Please reach
          # out to us if you encounter this
          raise Karafka::Errors::InvalidCoordinatorStateError, 'Was zero before decrementation'
        end
      end

      # Is all the consumption done and finished successfully for this coordinator
      # We do not say we're successful until all work is done, because running work may still
      # crash.
      def success?
        synchronize do
          @running_jobs.zero? && @consumptions.values.all?(&:success?)
        end
      end

      # Mark given consumption on consumer as successful
      # @param consumer [Karafka::BaseConsumer] consumer that finished successfully
      def success!(consumer)
        synchronize do
          consumption(consumer).success!
        end
      end

      # Mark given consumption on consumer as failed
      # @param consumer [Karafka::BaseConsumer] consumer that failed
      # @param error [StandardError] error that occurred
      def failure!(consumer, error)
        synchronize do
          @failure = true
          consumption(consumer).failure!(error)
        end
      end

      # @return [Boolean] true if any of work we were running failed
      def failure?
        @failure
      end

      # Marks given coordinator for processing group as revoked
      #
      # This is invoked in two places:
      #   - from the main listener loop when we detect revoked partitions
      #   - from the consumer in case checkpointing fails
      #
      # This means, we can end up having consumer being aware that it was revoked prior to the
      # listener loop dispatching the revocation job. It is ok, as effectively nothing will be
      # processed until revocation jobs are done.
      def revoke
        synchronize { @revoked = true }
      end

      # @return [Boolean] is the partition we are processing revoked or not
      def revoked?
        @revoked
      end

      # @return [Boolean] was the new seek offset assigned at least once. This is needed because
      #   by default we assign seek offset of a first message ever, however this is insufficient
      #   for DLQ in a scenario where the first message would be broken. We would never move
      #   out of it and would end up in an endless loop.
      def marked?
        @marked
      end

      # Store in the coordinator info, that this pause was done manually by the end user and not
      # by the system itself
      def manual_pause
        @manual_pause = true
      end

      # @return [Boolean] are we in a pause that was initiated by the user
      def manual_pause?
        @pause_tracker.paused? && @manual_pause
      end

      # Allows to run synchronized (locked) code that can operate in between virtual partitions
      # @param block [Proc] code we want to run in the synchronized mode
      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      private

      # @param consumer [Object] karafka consumer (normal or pro)
      # @return [Karafka::Processing::Result] result object which we can use to indicate
      #   consumption processing state.
      def consumption(consumer)
        @consumptions[consumer] ||= Processing::Result.new
      end
    end
  end
end
