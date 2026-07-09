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

require_relative '../../../../test_helper'

class Redmine::ApiRateLimiter::FailoverStoreTest < ActiveSupport::TestCase
  # A store that records calls and can be flipped to raise on demand.
  class FakeStore
    attr_accessor :fail
    attr_reader :calls

    def initialize
      @fail = false
      @calls = Hash.new(0)
    end

    def increment(*)
      @calls[:increment] += 1
      raise 'store down' if @fail

      1
    end

    def read(*)
      @calls[:read] += 1
      raise 'store down' if @fail

      nil
    end

    def write(*)
      @calls[:write] += 1
      raise 'store down' if @fail

      true
    end
  end

  # Subclass with a controllable monotonic clock so cooldown transitions are
  # deterministic (no sleeping, no Process::CLOCK_MONOTONIC dependency).
  class TestableFailoverStore < Redmine::ApiRateLimiter::FailoverStore
    attr_accessor :clock

    def initialize(**opts)
      @clock = 0.0
      super
    end

    private

    def monotonic
      @clock
    end
  end

  def setup
    @primary  = FakeStore.new
    @fallback = FakeStore.new
    @store = TestableFailoverStore.new(primary: @primary, fallback: @fallback,
                                       error_threshold: 3, cooldown: 30)
  end

  def test_healthy_calls_go_to_primary_only
    assert_equal 1, @store.increment('k')
    assert_equal 1, @primary.calls[:increment]
    assert_equal 0, @fallback.calls[:increment]
  end

  def test_single_primary_failure_degrades_that_call_to_fallback
    @primary.fail = true
    @store.increment('k')
    assert_equal 1, @primary.calls[:increment], 'primary was attempted'
    assert_equal 1, @fallback.calls[:increment], 'call degraded to fallback'
    # Below threshold: breaker still closed, next call retries the primary.
    @primary.fail = false
    @store.increment('k')
    assert_equal 2, @primary.calls[:increment]
  end

  def test_breaker_opens_after_threshold_and_sheds_to_fallback
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('api_rate_limiter.circuit_open') { events << true }

    @primary.fail = true
    3.times { @store.increment('k') } # trips at the 3rd consecutive failure

    assert_equal 1, events.size, 'circuit_open instrumented once'
    assert_equal 3, @primary.calls[:increment]

    # Breaker now open: further calls skip the primary entirely.
    @store.increment('k')
    assert_equal 3, @primary.calls[:increment], 'primary not touched while open'
    assert_equal 4, @fallback.calls[:increment]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def test_cooldown_half_opens_and_a_success_closes_the_breaker
    @primary.fail = true
    3.times { @store.increment('k') } # open

    # Before cooldown elapses -> still shedding to fallback.
    @store.clock = 29.0
    @store.increment('k')
    assert_equal 3, @primary.calls[:increment]

    # Cooldown elapsed and primary recovered -> half-open probe hits primary,
    # succeeds, and closes the breaker.
    @primary.fail = false
    @store.clock = 31.0
    assert_equal 1, @store.increment('k')
    assert_equal 4, @primary.calls[:increment], 'half-open probe hit primary'

    # Closed again: subsequent calls stay on the primary.
    @store.increment('k')
    assert_equal 5, @primary.calls[:increment]
  end

  def test_fallback_error_propagates
    @primary.fail = true
    @fallback.fail = true
    assert_raises(RuntimeError) { @store.increment('k') }
  end

  def test_read_and_write_are_delegated
    @store.write('k', 'v')
    @store.read('k')
    assert_equal 1, @primary.calls[:write]
    assert_equal 1, @primary.calls[:read]
  end
end
