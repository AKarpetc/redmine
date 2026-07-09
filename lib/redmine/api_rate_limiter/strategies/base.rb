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
      # Shared helpers for every strategy. A strategy is a pure function:
      #
      #   Strategy.consume(store:, key:, limit:, window:, now:, **opts) => Result
      #
      # It uses only the portable subset of the ActiveSupport::Cache API
      # (increment / read / write with expires_in), so any algorithm runs on any
      # configured store (subject to the caveats in feature-spec 3).
      #
      # Invariant for every counter strategy: INCREMENT FIRST, then compare.
      # Never read-then-increment - that races even on an atomic store.
      class Base
        # +consume+ must be implemented by each concrete strategy.
        def self.consume(store:, key:, now:, **_opts)
          raise NotImplementedError, "#{name} must implement .consume"
        end

        # Namespaced, nil-safe cache key. The window/bucket boundary is encoded
        # in the key (not the TTL) so reset semantics are identical across stores
        # regardless of how each store treats expires_in on increment (see 3c).
        def self.cache_key(*parts)
          "rl:#{parts.join(':')}"
        end

        # Human-friendly window label for the 429 message: "minute" for 60s,
        # otherwise "N seconds".
        def self.window_label(seconds)
          seconds.to_i == 60 ? 'minute' : "#{seconds.to_i} seconds"
        end
      end
    end
  end
end
