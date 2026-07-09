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
      # Sliding Window Counter - smooths the fixed-window boundary burst without
      # needing a sorted set. It keeps two fixed-window counters (current and
      # previous) and weights the previous one by how much of it still overlaps
      # the trailing window:
      #
      #   weighted = current + previous * (window - elapsed_in_current) / window
      #
      # Portable across all stores (two atomic increments + one read). Increment
      # first on the current window, then evaluate.
      class SlidingWindowCounter < Base
        def self.consume(store:, key:, limit:, window:, now:, **_opts)
          limit  = limit.to_i
          window = window.to_i
          epoch  = now.to_i
          label  = window_label(window)

          current_index = epoch / window
          prev_index    = current_index - 1
          elapsed       = epoch % window
          prev_weight   = (window - elapsed).to_f / window
          reset_at      = (current_index + 1) * window
          current_ckey  = cache_key('swc', key, current_index)
          prev_ckey     = cache_key('swc', key, prev_index)

          current = store.increment(current_ckey, 1, expires_in: window * 2)
          # Store failed open -> allow.
          return fail_open(limit: limit, reset_at: reset_at, window_label: label) if current.nil?

          # nil (missing or failed read) counts as 0 previous requests.
          previous = store.read(prev_ckey).to_i
          weighted = current + (previous * prev_weight)

          if weighted > limit
            Result.rejected(limit: limit, reset_at: reset_at,
                            retry_after: reset_at - epoch, window_label: label)
          else
            Result.allowed(limit: limit, remaining: limit - weighted.floor,
                           reset_at: reset_at, window_label: label)
          end
        end
      end
    end
  end
end
