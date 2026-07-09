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

# Applies API rate limiting to every API request (format xml|json), keyed per
# caller. Included into ApplicationController AFTER user_setup so User.current is
# resolved and authenticated callers are keyed by user id (Redmine #43881).
module ApiRateLimitable
  extend ActiveSupport::Concern

  included do
    before_action :check_api_rate_limit, if: :rate_limit_applicable?
  end

  class_methods do
    # Opt a controller or specific actions out of rate limiting (health checks,
    # monitoring endpoints, ...). Same signature as skip_before_action.
    #
    #   skip_rate_limit only: :index
    def skip_rate_limit(**options)
      skip_before_action :check_api_rate_limit, **options
    end
  end

  private

  # Only API requests are limited; HTML/UI traffic is never throttled here.
  def rate_limit_applicable?
    api_request?
  end

  def check_api_rate_limit
    result = Redmine::ApiRateLimiter.check(rate_limit_key)
    # Set X-RateLimit-* on the allowed path too, so clients can self-throttle.
    result.to_headers.each { |header, value| response.set_header(header, value) }
    return true if result.allowed?

    render_rate_limit_error(result)
    false
  rescue => e
    # FAIL OPEN (plan 3b): availability is chosen over enforcement. A storage
    # fault must never turn into a 500 on the API hot path. Instrument it (so a
    # silent degradation is still observable) and allow the request.
    ActiveSupport::Notifications.instrument('api_rate_limiter.error', error: e)
    Rails.logger.error("[api_rate_limiter] failing open: #{e.class}: #{e.message}") if Rails.logger
    true
  end

  # Per-caller key: authenticated -> user id; anonymous -> remote IP.
  def rate_limit_key
    User.current.logged? ? "user:#{User.current.id}" : "ip:#{request.remote_ip}"
  end

  # Dedicated 429 renderer for the exact contract in feature-spec 1.1, in the
  # caller's format. Deliberately NOT render_error, whose {"errors":[...]}
  # envelope differs. The X-RateLimit-* / Retry-After headers set above survive
  # because we only render a body here.
  def render_rate_limit_error(result)
    message = l(:error_api_rate_limit_exceeded,
                limit: result.limit,
                window: result.window_label,
                retry_after: result.retry_after)
    body = {error: l(:error_api_rate_limit_short), message: message}
    respond_to do |format|
      format.json { render json: body, status: :too_many_requests }
      format.xml  { render xml: body, root: 'error', status: :too_many_requests }
      format.any  { render json: body, status: :too_many_requests }
    end
  end
end
