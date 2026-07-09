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

require_relative '../../../test_helper'
require 'tmpdir'

class Redmine::ApiRateLimiterTest < ActiveSupport::TestCase
  Result = Redmine::ApiRateLimiter::Result
  FW     = Redmine::ApiRateLimiter::Strategies::FixedWindow
  SWC    = Redmine::ApiRateLimiter::Strategies::SlidingWindowCounter
  TB     = Redmine::ApiRateLimiter::Strategies::TokenBucket

  def setup
    @store = ActiveSupport::Cache::MemoryStore.new
    Redmine::ApiRateLimiter.store = @store
  end

  # A store whose +increment+/+read+ always raise (Dalli/custom-store failure).
  def raising_store
    store = Object.new
    def store.increment(*); raise 'store down'; end
    def store.read(*); raise 'store down'; end
    def store.write(*); raise 'store down'; end
    store
  end

  # A store that mimics RedisCacheStore#failsafe: never raises, returns nil.
  def nil_store
    store = Object.new
    def store.increment(*); nil; end
    def store.read(*); nil; end
    def store.write(*); true; end
    store
  end

  # --- Result value object ---

  def test_result_disabled_carries_nil_limit_and_emits_no_headers
    result = Result.disabled
    assert result.allowed?
    assert_nil result.limit
    assert_equal({}, result.to_headers)
  end

  def test_result_allowed_to_headers
    headers = Result.allowed(limit: 10, remaining: 7, reset_at: 1_000, window_label: 'minute').to_headers
    assert_equal '10',   headers['X-RateLimit-Limit']
    assert_equal '7',    headers['X-RateLimit-Remaining']
    assert_equal '1000', headers['X-RateLimit-Reset']
    assert_not headers.key?('Retry-After')
  end

  def test_result_rejected_to_headers_includes_retry_after
    result = Result.rejected(limit: 10, reset_at: 1_000, retry_after: 42, window_label: 'minute')
    assert_not result.allowed?
    headers = result.to_headers
    assert_equal '0',  headers['X-RateLimit-Remaining']
    assert_equal '42', headers['Retry-After']
  end

  def test_result_normalizes_negative_remaining_and_zero_retry_after
    assert_equal 0, Result.allowed(limit: 5, remaining: -3, reset_at: 1).remaining
    assert_equal 1, Result.rejected(limit: 5, reset_at: 1, retry_after: 0).retry_after
  end

  # --- Facade ---

  def test_check_short_circuits_when_disabled
    with_settings rest_api_rate_limit_enabled: '0' do
      assert_nil Redmine::ApiRateLimiter.check('user:1').limit
    end
  end

  def test_check_counts_and_rejects_over_limit
    with_settings(fixed_settings(requests: 3)) do
      3.times { assert Redmine::ApiRateLimiter.check('user:42').allowed? }
      assert_not Redmine::ApiRateLimiter.check('user:42').allowed?
    end
  end

  def test_strategy_for_selects_from_registry
    assert_equal FW,  Redmine::ApiRateLimiter.strategy_for('fixed_window')
    assert_equal SWC, Redmine::ApiRateLimiter.strategy_for('sliding_window_counter')
    assert_equal TB,  Redmine::ApiRateLimiter.strategy_for('token_bucket')
  end

  def test_strategy_for_unknown_or_blank_falls_back_to_fixed_window
    assert_equal FW, Redmine::ApiRateLimiter.strategy_for('nonsense')
    assert_equal FW, Redmine::ApiRateLimiter.strategy_for('')
    assert_equal FW, Redmine::ApiRateLimiter.strategy_for(nil)
  end

  def test_store_resolves_from_config
    Redmine::ApiRateLimiter.reset_store!
    assert_kind_of ActiveSupport::Cache::MemoryStore, Redmine::ApiRateLimiter.store
  end

  # --- Fixed Window ---

  def test_fixed_window_allows_up_to_limit
    result = nil
    3.times { result = FW.consume(store: @store, key: 'k', limit: 3, window: 60, now: Time.current) }
    assert result.allowed?
    assert_equal 0, result.remaining
  end

  def test_fixed_window_rejects_over_limit
    3.times { FW.consume(store: @store, key: 'k', limit: 3, window: 60, now: Time.current) }
    result = FW.consume(store: @store, key: 'k', limit: 3, window: 60, now: Time.current)
    assert_not result.allowed?
    assert_equal 0, result.remaining
    assert_operator result.retry_after, :>=, 1
  end

  def test_fixed_window_header_values_match_spec
    at = Time.utc(2026, 1, 1, 0, 0, 30) # 30s into a 60s window
    travel_to(at) do
      result = FW.consume(store: @store, key: 'k', limit: 5, window: 60, now: Time.current)
      assert_equal 5, result.limit
      assert_equal 4, result.remaining
      assert_equal(((at.to_i / 60) + 1) * 60, result.reset_at)
    end
  end

  def test_fixed_window_nil_counter_is_allowed
    result = FW.consume(store: nil_store, key: 'k', limit: 3, window: 60, now: Time.current)
    assert result.allowed?
  end

  # Portability claim (plan 3c): rotating-key reset semantics are identical
  # across stores despite their differing increment+TTL behavior.
  def test_fixed_window_reset_semantics_are_identical_across_stores
    Dir.mktmpdir do |dir|
      stores = {
        memory_store: ActiveSupport::Cache::MemoryStore.new,
        file_store:   ActiveSupport::Cache::FileStore.new(dir)
      }
      stores.each do |name, store|
        at = Time.utc(2026, 3, 1, 12, 0, 0)
        travel_to(at) do
          3.times { FW.consume(store: store, key: 'k', limit: 3, window: 60, now: Time.current) }
          assert_not FW.consume(store: store, key: 'k', limit: 3, window: 60, now: Time.current).allowed?,
                     "#{name}: 4th request in-window should be rejected"
        end
        travel_to(at + 61) do
          assert FW.consume(store: store, key: 'k', limit: 3, window: 60, now: Time.current).allowed?,
                 "#{name}: counter should reset after the window"
        end
      end
    end
  end

  # --- Sliding Window Counter ---

  def test_sliding_window_counter_allows_then_rejects
    travel_to(Time.utc(2026, 1, 1, 0, 0, 0)) do
      3.times { assert SWC.consume(store: @store, key: 'k', limit: 3, window: 60, now: Time.current).allowed? }
      assert_not SWC.consume(store: @store, key: 'k', limit: 3, window: 60, now: Time.current).allowed?
    end
  end

  def test_sliding_window_counter_weights_previous_window
    base = Time.utc(2026, 1, 1, 0, 0, 0)
    travel_to(base) do
      3.times { SWC.consume(store: @store, key: 'k', limit: 3, window: 60, now: Time.current) }
    end
    # Early in the next window the previous window still weighs ~1.0 -> reject.
    travel_to(base + 61) do
      assert_not SWC.consume(store: @store, key: 'k', limit: 3, window: 60, now: Time.current).allowed?
    end
    # Late in the next window the previous window has mostly slid out -> allow.
    travel_to(base + 119) do
      assert SWC.consume(store: @store, key: 'k', limit: 3, window: 60, now: Time.current).allowed?
    end
  end

  def test_sliding_window_counter_nil_counter_is_allowed
    result = SWC.consume(store: nil_store, key: 'k', limit: 3, window: 60, now: Time.current)
    assert result.allowed?
  end

  # --- Token Bucket (sequential only; see plan 3a for the concurrency caveat) ---

  def test_token_bucket_allows_burst_then_rejects
    travel_to(Time.utc(2026, 1, 1, 0, 0, 0)) do
      3.times { assert TB.consume(store: @store, key: 'k', burst: 3, refill_rate: 1.0, now: Time.current).allowed? }
      result = TB.consume(store: @store, key: 'k', burst: 3, refill_rate: 1.0, now: Time.current)
      assert_not result.allowed?
      assert_equal 3, result.limit
      assert_operator result.retry_after, :>=, 1
    end
  end

  def test_token_bucket_refills_over_time
    base = Time.utc(2026, 1, 1, 0, 0, 0)
    travel_to(base) do
      3.times { TB.consume(store: @store, key: 'k', burst: 3, refill_rate: 1.0, now: Time.current) }
      assert_not TB.consume(store: @store, key: 'k', burst: 3, refill_rate: 1.0, now: Time.current).allowed?
    end
    travel_to(base + 2) do # ~2 tokens refilled at 1 token/s
      assert TB.consume(store: @store, key: 'k', burst: 3, refill_rate: 1.0, now: Time.current).allowed?
    end
  end

  def test_token_bucket_header_values
    travel_to(Time.utc(2026, 1, 1, 0, 0, 0)) do
      result = TB.consume(store: @store, key: 'k', burst: 5, refill_rate: 2.0, now: Time.current)
      assert result.allowed?
      assert_equal 5, result.limit
      assert_equal 4, result.remaining
    end
  end

  def test_token_bucket_nil_read_starts_full_and_allows
    result = TB.consume(store: nil_store, key: 'k', burst: 3, refill_rate: 1.0, now: Time.current)
    assert result.allowed?
  end

  # --- Fail-open at the facade layer: a raising store propagates (the concern
  #     rescues it); here we assert the strategy does not silently swallow it. ---

  def test_raising_store_propagates_from_strategy
    assert_raises(RuntimeError) do
      FW.consume(store: raising_store, key: 'k', limit: 3, window: 60, now: Time.current)
    end
  end

  private

  def fixed_settings(requests: 3, window: 60)
    {
      rest_api_rate_limit_enabled:   '1',
      rest_api_rate_limit_algorithm: 'fixed_window',
      rest_api_rate_limit_requests:  requests.to_s,
      rest_api_rate_limit_window:    window.to_s
    }
  end
end
