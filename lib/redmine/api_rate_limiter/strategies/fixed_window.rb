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
      # Fixed Window counter - the default. Extremely low memory, portable across
      # every store via atomic +increment+. Trade-off: allows up to 2x the limit
      # across a window boundary (documented; operators wanting smoothing switch
      # to sliding_window_counter).
      #
      # Rotating-key design (plan 3c): the window index is part of the cache key
      # and the TTL is used only for garbage collection (window * 2). This gives
      # identical reset semantics on :memory_store, :file_store and Redis, sparing
      # us the increment+TTL divergence between stores.
      class FixedWindow < Base
        def self.consume(store:, key:, limit:, window:, now:, **_opts)
          limit  = limit.to_i
          window = window.to_i
          epoch  = now.to_i

          bucket   = epoch / window
          ckey     = cache_key('fw', key, bucket)
          reset_at = (bucket + 1) * window
          label    = window_label(window)

          # Increment first (atomic), then compare. A nil count means the store
          # failed open (e.g. RedisCacheStore#failsafe swallowed a connection
          # error) - allow the request rather than NoMethodError -> 500.
          count = store.increment(ckey, 1, expires_in: window * 2)
          if count.nil?
            return Result.allowed(limit: limit, remaining: limit - 1,
                                  reset_at: reset_at, window_label: label)
          end

          if count > limit
            Result.rejected(limit: limit, reset_at: reset_at,
                            retry_after: reset_at - epoch, window_label: label)
          else
            Result.allowed(limit: limit, remaining: limit - count,
                           reset_at: reset_at, window_label: label)
          end
        end
      end
    end
  end
end
