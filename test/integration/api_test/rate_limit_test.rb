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
      3.times { get '/projects.json', :headers => auth }
      get '/projects.json', :headers => auth

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
      4.times { get '/projects.xml', :headers => auth }

      assert_response :too_many_requests
      assert_equal 'application/xml', response.media_type
      assert_includes response.body, 'Rate limit exceeded'
    end
  end

  def test_two_users_have_isolated_buckets
    other = User.generate!
    other_token = Token.create!(:user => other, :action => 'api')
    with_settings(RATE) do
      3.times { get '/projects.json', :headers => auth }
      get '/projects.json', :headers => auth
      assert_response :too_many_requests

      # A different caller has its own bucket and is unaffected.
      get '/projects.json', :headers => {'X-Redmine-API-Key' => other_token.value.to_s}
      assert_response :success
    end
  end

  def test_anonymous_requests_are_keyed_by_ip
    with_settings(RATE) do
      3.times do
        get '/projects.json'
        assert_response :success
      end
      get '/projects.json'
      assert_response :too_many_requests
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
      3.times { get '/projects.json', :headers => auth }
      get '/projects.json', :headers => auth
      assert_response :too_many_requests

      travel(2.seconds) do
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
