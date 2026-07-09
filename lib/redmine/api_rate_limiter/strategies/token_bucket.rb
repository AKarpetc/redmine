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
    module Strategies
      # Token Bucket - a bucket of +burst+ tokens refills at +refill_rate+
      # tokens/second; each request costs one token. Absorbs organic bursts while
      # bounding the sustained rate.
      #
      # IMPORTANT (plan 3a): this is a read-modify-write over the generic cache
      # API - read {tokens, updated_at}, refill in Ruby, write back. Those are
      # separate cache calls with no lock across the gap, so it is EXACT on a
      # single-process :memory_store but APPROXIMATE on a shared store under
      # concurrency (two requests can read the same stale count and both pass).
      # The exact fix (Redis WATCH/MULTI or a Lua script) is out of this slice.
      class TokenBucket < Base
        def self.consume(store:, key:, burst:, refill_rate:, now:, **_opts)
          burst       = burst.to_i
          refill_rate = refill_rate.to_f
          at          = now.to_f
          ckey        = cache_key('tb', key)
          label       = "#{burst} requests"
          ttl         = ttl_for(burst, refill_rate)

          state = store.read(ckey)
          tokens, updated_at =
            if state.is_a?(Hash)
              [state[:tokens].to_f, state[:updated_at].to_f]
            else
              # First request for this key, or the store failed open (read -> nil):
              # start from a full bucket.
              [burst.to_f, at]
            end

          # Refill by elapsed time, capped at capacity.
          elapsed = [at - updated_at, 0.0].max
          tokens  = [tokens + (elapsed * refill_rate), burst.to_f].min

          if tokens >= 1.0
            tokens -= 1.0
            store.write(ckey, {tokens: tokens, updated_at: at}, expires_in: ttl)
            # reset_at: when the bucket would be full again.
            reset_at = refill_rate.positive? ? at + ((burst - tokens) / refill_rate) : at
            Result.allowed(limit: burst, remaining: tokens.floor,
                           reset_at: reset_at.to_i, window_label: label)
          else
            # Refill still advances even though we reject, so persist the new
            # updated_at (but not a consumed token).
            store.write(ckey, {tokens: tokens, updated_at: at}, expires_in: ttl)
            wait     = refill_rate.positive? ? (1.0 - tokens) / refill_rate : ttl
            reset_at = at + wait
            Result.rejected(limit: burst, reset_at: reset_at.to_i,
                            retry_after: wait.ceil, window_label: label)
          end
        end

        # Expire idle buckets once they would have fully refilled from empty
        # (plus a margin); keeps active buckets alive, GCs abandoned ones.
        def self.ttl_for(burst, refill_rate)
          return 3600 unless refill_rate.positive?

          ((burst / refill_rate).ceil * 2) + 1
        end
      end
    end
  end
end
