--!strict
--[[
	RateLimiter
	Per-player token bucket for gameplay remotes (GDD section 18).

	Goal: reject impossible request floods without punishing normal lag. A bucket
	refills continuously rather than resetting on a fixed window, so a player who
	lags and then fires two legitimate requests back to back is not denied.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable(
	{} :: {
		perSecond: number,
		burst: number,
		buckets: { [Player]: { tokens: number, updated: number } },
	},
	RateLimiter
))

--- `perSecond` sustained requests, allowing a short burst of `burst` (default 2x).
function RateLimiter.new(perSecond: number, burst: number?): RateLimiter
	return setmetatable({
		perSecond = perSecond,
		burst = burst or math.max(perSecond * 2, perSecond + 1),
		buckets = {},
	}, RateLimiter)
end

--- Consumes one token. Returns false when the player is over budget.
function RateLimiter.consume(self: RateLimiter, player: Player): boolean
	local now = os.clock()
	local bucket = self.buckets[player]

	if not bucket then
		bucket = { tokens = self.burst, updated = now }
		self.buckets[player] = bucket
	end

	bucket.tokens = math.min(self.burst, bucket.tokens + (now - bucket.updated) * self.perSecond)
	bucket.updated = now

	if bucket.tokens < 1 then
		return false
	end

	bucket.tokens -= 1
	return true
end

--- Must be called on PlayerRemoving so buckets cannot leak.
function RateLimiter.release(self: RateLimiter, player: Player)
	self.buckets[player] = nil
end

return RateLimiter
