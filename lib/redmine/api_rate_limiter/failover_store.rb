# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

module Redmine
  module ApiRateLimiter
    # Availability layer 2 (feature-spec 2.1 / plan 3b) - DEFERRED EXTENSION POINT.
    #
    # This class is fully implemented but intentionally NOT wired at boot in this
    # slice: the core already fails open, so availability does not depend on it.
    # It is shipped as the concrete design artifact for the failover story and can
    # be enabled by wrapping the resolved store at boot:
    #
    #   Redmine::ApiRateLimiter.store = Redmine::ApiRateLimiter::FailoverStore.new(
    #     primary:  ActiveSupport::Cache.lookup_store(config.redmine_api_rate_limit_cache_store),
    #     fallback: ActiveSupport::Cache::MemoryStore.new(size: 32.megabytes)
    #   )
    #
    # Because every strategy receives the store as a parameter, failover is a
    # store DECORATOR - the strategies and the controller are unchanged. It
    # implements the same portable subset used by the strategies (increment /
    # read / write) over a primary (e.g. Redis) and a fallback (MemoryStore)
    # behind a circuit breaker: consecutive primary errors trip the breaker and
    # route to the fallback; a monotonic-clock cooldown half-opens to probe
    # recovery; a success closes it again.
    #
    # Honest degradation semantics (documented in README_RATE_LIMITING.md):
    #   * failover from a SHARED store to a PER-PROCESS fallback silently changes
    #     the guarantee from one global limit to limit x processes;
    #   * the fallback starts at zero, so a burst is briefly allowed at failover;
    #   * primary/fallback counts diverge until recovery.
    # Degrading to a per-process ceiling is deliberately preferred over "fully
    # open"; breaker transitions are instrumented so the degradation is alertable.
    class FailoverStore
      PORTABLE_OPS = %i[increment read write].freeze

      def initialize(primary:, fallback:, error_threshold: 5, cooldown: 30)
        @primary = primary
        @fallback = fallback
        @error_threshold = error_threshold
        @cooldown = cooldown
        @mutex = Mutex.new           # Puma is multi-threaded: breaker state must be safe
        @failures = 0
        @open_until = nil            # nil = closed; set = tripped-open deadline (monotonic)
      end

      PORTABLE_OPS.each do |op|
        define_method(op) do |*args, **kwargs|
          store = choose_store
          begin
            result = store.public_send(op, *args, **kwargs)
            record_success if store.equal?(@primary)
            result
          rescue StandardError
            raise unless store.equal?(@primary)

            # Primary failed: trip toward open and degrade THIS call to the fallback.
            record_failure
            @fallback.public_send(op, *args, **kwargs)
          end
        end
      end

      private

      def choose_store
        @mutex.synchronize do
          return @primary if @open_until.nil?

          if monotonic >= @open_until
            @open_until = nil        # cooldown elapsed -> half-open probe on the primary
            @primary
          else
            @fallback                # still open -> shed to fallback
          end
        end
      end

      def record_failure
        @mutex.synchronize do
          @failures += 1
          if @failures >= @error_threshold
            @open_until = monotonic + @cooldown
            ActiveSupport::Notifications.instrument('api_rate_limiter.circuit_open')
          end
        end
      end

      def record_success
        @mutex.synchronize do
          @failures = 0
          @open_until = nil
        end
      end

      # Monotonic clock so NTP steps never distort the cooldown window.
      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
