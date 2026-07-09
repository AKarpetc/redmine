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

require_relative '../../test_helper'

class Redmine::ApiTest::RateLimitTest < Redmine::ApiTest::Base
  # Low, deterministic limits for the tests. Fixed window / 3 requests / 60s.
  RATE = {
    rest_api_rate_limit_enabled:   '1',
    rest_api_rate_limit_algorithm: 'fixed_window',
    rest_api_rate_limit_requests:  '3',
    rest_api_rate_limit_window:    '60'
  }.freeze

  def setup
    super # enables rest_api
    @user  = User.generate!
    @token = Token.create!(:user => @user, :action => 'api')
    # The test env Rails.cache is :null_store; the limiter uses its own store
    # (config.redmine_api_rate_limit_cache_store => :memory_store). Inject a
    # fresh one so each test starts with empty counters.
    Redmine::ApiRateLimiter.store = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    super
    Redmine::ApiRateLimiter.reset_store!
  end

  def auth
    {'X-Redmine-API-Key' => @token.value.to_s}
  end

  # Pin the clock so a burst of requests lands in a single fixed window even on
  # a slow CI runner. Without this, a real-clock window boundary can split the
  # burst, the rotating-key counter resets mid-test, and the 429 assertion flakes.
  def in_single_window(&)
    travel_to(Time.utc(2026, 1, 1, 12, 0, 0), &)
  end

  def test_requests_under_limit_all_succeed
    with_settings(RATE) do
      3.times do
        get '/projects.json', :headers => auth
        assert_response :success
      end
    end
  end

  def test_over_limit_returns_429_with_headers_and_json_body
    with_settings(RATE) do
      in_single_window do
        3.times { get '/projects.json', :headers => auth }
        get '/projects.json', :headers => auth
      end

      assert_response :too_many_requests
      assert_equal '3', response.headers['X-RateLimit-Limit']
      assert_equal '0', response.headers['X-RateLimit-Remaining']
      assert_operator response.headers['X-RateLimit-Reset'].to_i, :>, 0
      assert_operator response.headers['Retry-After'].to_i, :>=, 1

      json = ActiveSupport::JSON.decode(response.body)
      assert_equal 'Rate limit exceeded', json['error']
      assert_includes json['message'], 'rate limit'
    end
  end

  def test_over_limit_returns_429_with_xml_body
    with_settings(RATE) do
      in_single_window { 4.times { get '/projects.xml', :headers => auth } }

      assert_response :too_many_requests
      assert_equal 'application/xml', response.media_type
      assert_includes response.body, 'Rate limit exceeded'
      # Structured body rendered under an <error> root (not render_error's envelope).
      doc = Hash.from_xml(response.body)
      assert doc.key?('error'), 'expected an <error> root element'
      assert_equal 'Rate limit exceeded', doc['error']['error']
      assert_includes doc['error']['message'], 'rate limit'
    end
  end

  # End-to-end proof that the algorithm is swappable at runtime via Setting,
  # with no restart and no code change (token bucket: burst then throttle).
  def test_algorithm_is_switchable_via_setting
    with_settings(RATE.merge(:rest_api_rate_limit_algorithm => 'token_bucket',
                             :rest_api_rate_limit_burst => '3',
                             :rest_api_rate_limit_refill_rate => '0.01')) do
      in_single_window do
        3.times do
          get '/projects.json', :headers => auth
          assert_response :success
        end
        get '/projects.json', :headers => auth
      end
      assert_response :too_many_requests
      assert_equal '3', response.headers['X-RateLimit-Limit']
    end
  end

  # A misconfigured window (0) must not 500 the API: the facade clamps it.
  def test_zero_window_setting_does_not_error
    with_settings(RATE.merge(:rest_api_rate_limit_window => '0')) do
      get '/projects.json', :headers => auth
      assert_response :success
    end
  end

  def test_two_users_have_isolated_buckets
    other = User.generate!
    other_token = Token.create!(:user => other, :action => 'api')
    with_settings(RATE) do
      in_single_window do
        3.times { get '/projects.json', :headers => auth }
        get '/projects.json', :headers => auth
        assert_response :too_many_requests

        # A different caller has its own bucket and is unaffected.
        get '/projects.json', :headers => {'X-Redmine-API-Key' => other_token.value.to_s}
        assert_response :success
      end
    end
  end

  def test_anonymous_requests_are_keyed_by_ip
    with_settings(RATE) do
      in_single_window do
        3.times do
          get '/projects.json'
          assert_response :success
        end
        get '/projects.json'
        assert_response :too_many_requests
      end
    end
  end

  def test_disabled_never_limits_and_emits_no_headers
    with_settings(RATE.merge(:rest_api_rate_limit_enabled => '0')) do
      5.times do
        get '/projects.json', :headers => auth
        assert_response :success
      end
      assert_nil response.headers['X-RateLimit-Limit']
    end
  end

  def test_html_requests_are_never_throttled
    with_settings(RATE) do
      6.times do
        get '/projects'
        assert_response :success
      end
      assert_nil response.headers['X-RateLimit-Limit']
    end
  end

  def test_counter_resets_after_window
    with_settings(RATE.merge(:rest_api_rate_limit_window => '1')) do
      # Burst pinned to one 1s window so the 4th request is deterministically over.
      travel_to(Time.utc(2026, 1, 1, 12, 0, 0)) do
        3.times { get '/projects.json', :headers => auth }
        get '/projects.json', :headers => auth
        assert_response :too_many_requests
      end

      # A later window uses a fresh rotating key -> the counter has reset.
      travel_to(Time.utc(2026, 1, 1, 12, 0, 2)) do
        get '/projects.json', :headers => auth
        assert_response :success
      end
    end
  end

  def test_fails_open_when_store_raises
    boom = Object.new
    def boom.increment(*); raise 'store down'; end
    Redmine::ApiRateLimiter.store = boom

    events = []
    subscriber = ActiveSupport::Notifications.subscribe('api_rate_limiter.error') { events << true }

    with_settings(RATE) do
      get '/projects.json', :headers => auth
      assert_response :success # fail open, not 500
    end
    assert_equal 1, events.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def test_under_limit_headers_present_on_2xx
    with_settings(RATE) do
      get '/projects.json', :headers => auth
      assert_response :success
      assert_equal '3', response.headers['X-RateLimit-Limit']
      assert_equal '2', response.headers['X-RateLimit-Remaining']
      assert_operator response.headers['X-RateLimit-Reset'].to_i, :>, 0
      assert_nil response.headers['Retry-After']
    end
  end

  def test_skip_rate_limit_removes_the_before_action_for_a_controller
    exempt = Class.new(ApplicationController) { skip_rate_limit }
    filters = exempt._process_action_callbacks.map(&:filter)
    assert_not_includes filters, :check_api_rate_limit

    # The base controller still has it.
    assert_includes ApplicationController._process_action_callbacks.map(&:filter),
                    :check_api_rate_limit
  end
end
