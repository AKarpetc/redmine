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
  # Facade for API rate limiting (Redmine #43881, pillar 3).
  #
  # Two independent pluggability axes:
  #   * storage   - +.store+, resolved from config.redmine_api_rate_limit_cache_store
  #   * algorithm - a Strategy class chosen from REGISTRY by Setting
  #
  # Strategies receive the store as a parameter, so any strategy runs on any
  # store. The facade reads all configuration and returns a Result; the concern
  # (ApiRateLimitable) turns that Result into headers / a 429.
  module ApiRateLimiter
    # algorithm name (Setting value) => Strategy class
    REGISTRY = {
      'fixed_window'           => Strategies::FixedWindow,
      'sliding_window_counter' => Strategies::SlidingWindowCounter,
      'token_bucket'           => Strategies::TokenBucket
    }.freeze

    DEFAULT_ALGORITHM = 'fixed_window'

    class << self
      # The cache store used for counters. Defaults to the configured store,
      # resolved lazily so boot order and test injection both work. Assignable
      # for tests (the test env cache is :null_store, which cannot count).
      attr_writer :store

      def store
        @store ||= resolve_store
      end

      # Test seam: drop the memoized store so the next access re-resolves it.
      def reset_store!
        @store = nil
      end

      # Consume one request for +key+. Returns a Result. Never raises for a
      # normal miss - a nil counter from a failed store is treated as "allow" by
      # the strategies (fail-open at the strategy layer, plan 3b).
      def check(key)
        return Result.disabled unless Setting.rest_api_rate_limit_enabled?

        strategy_for(Setting.rest_api_rate_limit_algorithm)
          .consume(store: store, key: key, now: Time.current, **strategy_params)
      end

      # Resolve the strategy class for an algorithm name; unknown or blank falls
      # back to the default (fixed_window).
      def strategy_for(algorithm)
        REGISTRY[algorithm.to_s.presence || DEFAULT_ALGORITHM] || REGISTRY[DEFAULT_ALGORITHM]
      end

      private

      # All configurable parameters, read fresh each request so Setting changes
      # take effect without a restart. Strategies pick the keys they need and
      # swallow the rest via **opts.
      #
      # Values are clamped defensively: the Setting layer validates integer-ness
      # but not range, so an admin typo (e.g. window = 0) must not reach a
      # strategy and divide by zero on the API hot path. +window+ floors at 1s;
      # counts/rates floor at 0 (0 = block everything, a deliberate choice).
      def strategy_params
        {
          limit:       [Setting.rest_api_rate_limit_requests.to_i, 0].max,
          window:      [Setting.rest_api_rate_limit_window.to_i, 1].max,
          burst:       [Setting.rest_api_rate_limit_burst.to_i, 0].max,
          refill_rate: [Setting.rest_api_rate_limit_refill_rate.to_f, 0.0].max
        }
      end

      def resolve_store
        config =
          begin
            Rails.application.config.redmine_api_rate_limit_cache_store
          rescue NameError
            # Config accessor not defined yet (boot ordering, NoMethodError is a
            # NameError) - use the default.
            :memory_store
          end
        config ||= :memory_store
        ActiveSupport::Cache.lookup_store(config)
      end
    end
  end
end
