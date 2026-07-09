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
    # Value object returned by every strategy. It carries the four values the
    # HTTP contract needs (feature-spec 1.1) so the concern renders one uniform
    # response regardless of which algorithm produced it.
    #
    #   limit        -> X-RateLimit-Limit      (ceiling for the window/bucket)
    #   remaining    -> X-RateLimit-Remaining  (non-negative; 0 on a reject)
    #   reset_at     -> X-RateLimit-Reset      (UTC epoch seconds)
    #   retry_after  -> Retry-After            (positive integer; reject only)
    #
    # A disabled limiter yields a Result with a nil +limit+ so #to_headers emits
    # nothing and no X-RateLimit-* headers leak onto responses.
    class Result
      attr_reader :limit, :remaining, :reset_at, :retry_after, :window_label

      # An allowed request. +remaining+ is floored at 0.
      def self.allowed(limit:, remaining:, reset_at:, window_label: nil)
        new(allowed: true, limit: limit, remaining: [remaining.to_i, 0].max,
            reset_at: reset_at, retry_after: nil, window_label: window_label)
      end

      # A rejected request. +remaining+ is always 0; +retry_after+ is forced to a
      # positive integer so a client never busy-loops on Retry-After: 0.
      def self.rejected(limit:, reset_at:, retry_after:, window_label: nil)
        new(allowed: false, limit: limit, remaining: 0, reset_at: reset_at,
            retry_after: [retry_after.to_i, 1].max, window_label: window_label)
      end

      # The limiter is turned off. Carries a nil limit -> no headers, always allowed.
      def self.disabled
        new(allowed: true, limit: nil, remaining: nil, reset_at: nil,
            retry_after: nil, window_label: nil)
      end

      def initialize(allowed:, limit:, remaining:, reset_at:, retry_after:, window_label:)
        @allowed = allowed
        @limit = limit
        @remaining = remaining
        @reset_at = reset_at
        @retry_after = retry_after
        @window_label = window_label
      end

      def allowed?
        @allowed
      end

      # Single source of header truth, used on both 2xx and 429 responses so the
      # values are always consistent. Returns {} when the limiter is disabled.
      def to_headers
        return {} if limit.nil?

        headers = {
          'X-RateLimit-Limit'     => limit.to_s,
          'X-RateLimit-Remaining' => remaining.to_i.to_s,
          'X-RateLimit-Reset'     => reset_at.to_i.to_s
        }
        headers['Retry-After'] = retry_after.to_s unless allowed?
        headers
      end
    end
  end
end
