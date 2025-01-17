local player, layout = ...
local pn = ToEnumShortString(player)
local mods = SL[pn].ActiveModifiers

if not mods.SubtractiveScoring then return end

-- don't allow SubtractiveScoring to appear in Casual gamemode via profile settings
if SL.Global.GameMode == "Casual" then return end

-- -----------------------------------------------------------------------

local metrics = SL.Metrics[SL.Global.GameMode]
-- a flag to determine if we are using a GameMode that utilizes FA+ timing windows
local FAplus = (metrics.PercentScoreWeightW1 == metrics.PercentScoreWeightW2)
local undesirable_judgment = FAplus and "W3" or "W2"

-- flag to determine whether to bother to continue counting excellents
-- or whether to just display percent away from 100%
local received_judgment_lower_than_desired = false

-- this starts at 0 for each song/course
-- (but does not reset to 0 between each song in a course)
local undesirable_judgment_count = 0

-- variables for tapnotescore and holdnotescore that need file scope
local tns, hns

local pss = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)

-- -----------------------------------------------------------------------
-- which font should we use for the BitmapText actor?
local font = mods.ComboFont

-- most ComboFonts have their own dedicated sprite sheets in ./Simply Love/Fonts/_Combo Fonts/
-- "Wendy" and "Wendy (Cursed)" are exceptions for the time being
-- reroute both to use "./Fonts/Wendy/_wendy small"
if font == "Wendy" or font == "Wendy (Cursed)" then
	font = "Wendy/_wendy small"
else
	font = "_Combo Fonts/" .. font .. "/"
end

-- -----------------------------------------------------------------------
local GetPossibleExScore = function(counts)
	local best_counts = {}
	
	local keys = { "W0", "W1", "W2", "W3", "W4", "W5", "Miss", "Held", "LetGo", "HitMine" }

	for key in ivalues(keys) do
		local value = counts[key]
		if value ~= nil then
			-- Initialize the keys	
			if best_counts[key] == nil then
				best_counts[key] = 0
			end

			-- Upgrade dropped holds/rolls to held.
			if key == "LetGo" or key == "Held" then
				best_counts["Held"] = best_counts["Held"] + value
			-- We never hit any mines.
			elseif key == "HitMine" then
				best_counts[key] = 0
			-- Upgrade to FA+ window.
			else
				best_counts["W0"] = best_counts["W0"] + value
			end
		end
	end

	local possible_ex_score, possible_total = CalculateExScore(player, best_counts)
	return possible_ex_score, possible_total
end

-- -----------------------------------------------------------------------

-- the BitmapText actor
local bmt = LoadFont(font)

bmt.InitCommand=function(self)
	self:diffuse(color("#ff55cc"))
	self:zoom(0.35):shadowlength(1):horizalign(center)

	local width = GetNotefieldWidth()
	local NumColumns = GAMESTATE:GetCurrentStyle():ColumnsPerPlayer()
	-- mirror image of MeasureCounter.lua
	self:xy(GetNotefieldX(player) + (width/NumColumns), layout.y)

	-- Fix overlap issues when MeasureCounter is centered
	-- since in this case we don't need symmetry.
	if (mods.MeasureCounterLeft == false) then
		self:horizalign(left)
		-- nudge slightly left (15% of the width of the bitmaptext when set to "100.00%")
		self:settext("100.00%"):addx( -self:GetWidth()*self:GetZoom() * 0.15 )
		self:settext("")
	end
end

bmt.JudgmentMessageCommand=function(self, params)
	if player == params.Player and not mods.ShowEXScore then
		tns = ToEnumShortString(params.TapNoteScore)
		hns = params.HoldNoteScore and ToEnumShortString(params.HoldNoteScore)
		self:queuecommand("SetScore")
	end
end


bmt.ExCountsChangedMessageCommand=function(self, params)
	if player == params.Player and mods.ShowEXScore then
		local possible_ex_score, current_possible = GetPossibleExScore(params.ExCounts)
		local total_possible = params.ActualPossible
		local current_points = params.ActualPoints
		local dp_lost = current_possible - current_points
		local score = 100 - math.floor((total_possible-dp_lost) / total_possible * 10000) / 100
		
		-- handle floating point equality.
		if score >= 0.0001 then
			self:settext( ("-%.2f%%"):format(score) )
		end
	end
end


-- This is a bit convoluted!
-- If this is a W2/undesirable_judgment, then we want to count up to 10 with them,
-- unless we get some other judgment worse than W2/undesirable_judgment.
-- The complication is in how hold notes are counted.
--
-- Hold note judgments contain a copy of the tap
-- note judgment that started it (because it affects your life regen?), so
-- we have to be careful not to double count it against you.  But we also
-- want a dropped hold to trigger the percentage scoring.  So the
-- choice is having a more straightforward if else structure, but at the
-- expense of repeating the percent displaying code vs a more complicated
-- if else structure. DRY, so second.

bmt.SetScoreCommand=function(self, params)
	-- used to determine if a player has failed yet
	local topscreen = SCREENMAN:GetTopScreen()

	-- if the player adjusts the sync of the stepchart during gameplay, they will eventually
	-- reach ScreenPrompt, where they'll be prompted to accept or reject the sync changes.
	-- Although the screen changes, this Lua sticks around, and the TopScreen will no longer
	-- have a GetLifeMeter() method.
	if topscreen.GetLifeMeter == nil then return end

	-- change the threshold if gamemode is DDR
	undesirable_threshold = 10
	if SL.Global.GameMode == "DDR" then
		undesirable_threshold = 50
	end

	-- if this is an undesirable judgment AND we can still count up AND it's not a dropped hold
	if tns == undesirable_judgment
	and not received_judgment_lower_than_desired
	and undesirable_judgment_count < undesirable_threshold
	and (hns ~= "LetGo") then
		-- if this is the tail of a hold note, don't double count it
		if not hns then
			-- increment up to the threshold
			undesirable_judgment_count = undesirable_judgment_count + 1
			-- and specify literal W2 count
			self:settext("-" .. undesirable_judgment_count)
		end

	-- else if this wouldn't subtract from percentage (W1 or mine miss)
	elseif (((FAplus and tns ~= "W1" and tns ~= "W2") or (not FAplus and tns ~= "W1")) and tns ~= "AvoidMine")
	-- unless it actually would subtract from percentage (W1 + let go)
	or (hns == "LetGo")
	-- or we're already dead (and so can't gain any percentage.)
	or (topscreen:GetLifeMeter(player):IsFailing()) then

		received_judgment_lower_than_desired = true

		-- FIXME: I really need to figure out what the calculations are doing and describe that here.  -quietly

		-- PossibleDancePoints and CurrentPossibleDancePoints change as the song progresses and judgments
		-- are earned by the player; these values need to be continually fetched from the engine
		local possible_dp = pss:GetPossibleDancePoints()
		local current_possible_dp = pss:GetCurrentPossibleDancePoints()

		-- max to prevent subtractive scoring reading more than -100%
		local actual_dp = math.max(pss:GetActualDancePoints(), 0)

		local score = current_possible_dp - actual_dp
		score = math.floor(((possible_dp - score) / possible_dp) * 10000) / 100

		-- specify percent away from 100%
		self:settext( ("-%.2f%%"):format(100-score) )
	end
end

return bmt
