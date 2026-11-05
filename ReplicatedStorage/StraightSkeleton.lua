local StraightSkeleton = {}

local EPS = 1e-6
local SNAP_TOLERANCE = 0.5
local KEY_EPS = 0.05

local function v2(x, z)
	return { x = x, z = z }
end

local function clonePoint(point)
	return { x = point.x, z = point.z }
end

local function toPoint(value)
	if typeof(value) == "Vector2" then
		return v2(value.X, value.Y)
	end
	if typeof(value) == "Vector3" then
		return v2(value.X, value.Z)
	end
	local x = value.x or value.X
	local z = value.z or value.Z or value.y or value.Y
	if type(x) ~= "number" or type(z) ~= "number" then
		return nil
	end
	return v2(x, z)
end

local function approx(a, b, tolerance)
	tolerance = tolerance or EPS
	return math.abs(a - b) <= tolerance
end

local function samePoint(a, b, tolerance)
	tolerance = tolerance or EPS
	return approx(a.x, b.x, tolerance) and approx(a.z, b.z, tolerance)
end

local function signedArea(polygon)
	local area = 0
	for i = 1, #polygon do
		local a = polygon[i]
		local b = polygon[(i % #polygon) + 1]
		area += (a.x * b.z) - (b.x * a.z)
	end
	return area * 0.5
end

local function reverseInPlace(list)
	local i = 1
	local j = #list
	while i < j do
		list[i], list[j] = list[j], list[i]
		i += 1
		j -= 1
	end
end

local function normalizeAxis(value)
	if math.abs(value) <= EPS then
		return 0
	end
	return value > 0 and 1 or -1
end

local function coordKey(value)
	return string.format("%.4f", value)
end

local function segmentKey(a, b)
	local startPoint = clonePoint(a)
	local endPoint = clonePoint(b)
	if approx(startPoint.z, endPoint.z, KEY_EPS) and startPoint.x > endPoint.x then
		startPoint, endPoint = endPoint, startPoint
	elseif approx(startPoint.x, endPoint.x, KEY_EPS) and startPoint.z > endPoint.z then
		startPoint, endPoint = endPoint, startPoint
	end
	return table.concat({
		coordKey(startPoint.x),
		coordKey(startPoint.z),
		coordKey(endPoint.x),
		coordKey(endPoint.z),
	}, ":")
end

local function uniqueSorted(values)
	table.sort(values)
	local result = {}
	for _, value in ipairs(values) do
		if #result == 0 or not approx(result[#result], value, KEY_EPS) then
			result[#result + 1] = value
		end
	end
	return result
end

local function clusterSnap(points, axisName)
	local values = {}
	for index, point in ipairs(points) do
		values[index] = {
			index = index,
			value = point[axisName],
		}
	end
	table.sort(values, function(a, b)
		return a.value < b.value
	end)

	local snapped = {}
	local i = 1
	while i <= #values do
		local sum = values[i].value
		local count = 1
		local clusterEnd = i
		while clusterEnd < #values and math.abs(values[clusterEnd + 1].value - values[clusterEnd].value) <= SNAP_TOLERANCE do
			clusterEnd += 1
			sum += values[clusterEnd].value
			count += 1
		end
		local average = sum / count
		for j = i, clusterEnd do
			snapped[values[j].index] = average
		end
		i = clusterEnd + 1
	end

	for index, point in ipairs(points) do
		point[axisName] = snapped[index]
	end
end

local function removeConsecutiveDuplicates(points)
	local result = {}
	for _, point in ipairs(points) do
		if #result == 0 or not samePoint(result[#result], point, SNAP_TOLERANCE) then
			result[#result + 1] = clonePoint(point)
		end
	end
	if #result >= 2 and samePoint(result[1], result[#result], SNAP_TOLERANCE) then
		table.remove(result, #result)
	end
	return result
end

local function removeCollinearVertices(points)
	local changed = true
	while changed and #points >= 3 do
		changed = false
		local filtered = {}
		for i = 1, #points do
			local prev = points[((i - 2) % #points) + 1]
			local curr = points[i]
			local next = points[(i % #points) + 1]
			local dx1 = normalizeAxis(curr.x - prev.x)
			local dz1 = normalizeAxis(curr.z - prev.z)
			local dx2 = normalizeAxis(next.x - curr.x)
			local dz2 = normalizeAxis(next.z - curr.z)
			local zeroLength = (dx1 == 0 and dz1 == 0) or (dx2 == 0 and dz2 == 0)
			local straight = dx1 == dx2 and dz1 == dz2
			if zeroLength or straight then
				changed = true
			else
				filtered[#filtered + 1] = curr
			end
		end
		points = filtered
	end
	return points
end

local function isAxisAlignedEdge(a, b)
	local dx = b.x - a.x
	local dz = b.z - a.z
	local horizontal = approx(dz, 0, KEY_EPS) and not approx(dx, 0, KEY_EPS)
	local vertical = approx(dx, 0, KEY_EPS) and not approx(dz, 0, KEY_EPS)
	return horizontal or vertical
end

local function segmentsOverlap(a1, a2, b1, b2)
	local aHorizontal = approx(a1.z, a2.z, KEY_EPS)
	local bHorizontal = approx(b1.z, b2.z, KEY_EPS)
	if aHorizontal ~= bHorizontal then
		local h1, h2, v1, v2 = a1, a2, b1, b2
		if not aHorizontal then
			h1, h2, v1, v2 = b1, b2, a1, a2
		end
		local hxMin = math.min(h1.x, h2.x)
		local hxMax = math.max(h1.x, h2.x)
		local vzMin = math.min(v1.z, v2.z)
		local vzMax = math.max(v1.z, v2.z)
		local touches = v1.x >= hxMin - KEY_EPS and v1.x <= hxMax + KEY_EPS and h1.z >= vzMin - KEY_EPS and h1.z <= vzMax + KEY_EPS
		if not touches then
			return false
		end
		local sharesEndpoint = samePoint(a1, b1, KEY_EPS) or samePoint(a1, b2, KEY_EPS) or samePoint(a2, b1, KEY_EPS) or samePoint(a2, b2, KEY_EPS)
		return not sharesEndpoint
	end

	if aHorizontal then
		if not approx(a1.z, b1.z, KEY_EPS) then
			return false
		end
		local aMin = math.min(a1.x, a2.x)
		local aMax = math.max(a1.x, a2.x)
		local bMin = math.min(b1.x, b2.x)
		local bMax = math.max(b1.x, b2.x)
		return math.max(aMin, bMin) < math.min(aMax, bMax) - KEY_EPS
	end

	if not approx(a1.x, b1.x, KEY_EPS) then
		return false
	end
	local aMin = math.min(a1.z, a2.z)
	local aMax = math.max(a1.z, a2.z)
	local bMin = math.min(b1.z, b2.z)
	local bMax = math.max(b1.z, b2.z)
	return math.max(aMin, bMin) < math.min(aMax, bMax) - KEY_EPS
end

local function validateSimpleOrthogonalPolygon(points)
	if #points < 4 then
		return false
	end

	for i = 1, #points do
		local a = points[i]
		local b = points[(i % #points) + 1]
		if not isAxisAlignedEdge(a, b) then
			return false
		end
	end

	for i = 1, #points do
		local prev = points[((i - 2) % #points) + 1]
		local curr = points[i]
		local next = points[(i % #points) + 1]
		local dx1 = normalizeAxis(curr.x - prev.x)
		local dz1 = normalizeAxis(curr.z - prev.z)
		local dx2 = normalizeAxis(next.x - curr.x)
		local dz2 = normalizeAxis(next.z - curr.z)
		if dx1 == dx2 and dz1 == dz2 then
			return false
		end
		if dx1 ~= 0 and dx2 ~= 0 then
			return false
		end
		if dz1 ~= 0 and dz2 ~= 0 then
			return false
		end
	end

	for i = 1, #points do
		local a1 = points[i]
		local a2 = points[(i % #points) + 1]
		for j = i + 1, #points do
			local adjacent = j == ((i - 2) % #points) + 1 or j == (i % #points) + 1 or (i == 1 and j == #points)
			if not adjacent then
				local b1 = points[j]
				local b2 = points[(j % #points) + 1]
				if segmentsOverlap(a1, a2, b1, b2) then
					return false
				end
			end
		end
	end

	return true
end

local function sanitizePolygon(polygon)
	local points = {}
	for _, value in ipairs(polygon or {}) do
		local point = toPoint(value)
		if not point then
			return nil, "Only orthogonal polygons allowed."
		end
		points[#points + 1] = point
	end

	points = removeConsecutiveDuplicates(points)
	if #points < 4 then
		return nil, "Only orthogonal polygons allowed."
	end

	clusterSnap(points, "x")
	clusterSnap(points, "z")
	points = removeConsecutiveDuplicates(points)
	points = removeCollinearVertices(points)

	if #points < 4 or not validateSimpleOrthogonalPolygon(points) then
		return nil, "Only orthogonal polygons allowed."
	end

	if signedArea(points) < 0 then
		reverseInPlace(points)
	end

	return points
end

local function buildRowIntervals(polygon, xs, zs)
	local intervals = {}
	for zi = 1, #zs - 1 do
		local zSample = (zs[zi] + zs[zi + 1]) * 0.5
		local crossings = {}
		for i = 1, #polygon do
			local a = polygon[i]
			local b = polygon[(i % #polygon) + 1]
			if approx(a.x, b.x, KEY_EPS) then
				local zMin = math.min(a.z, b.z)
				local zMax = math.max(a.z, b.z)
				if zSample > zMin + KEY_EPS and zSample < zMax - KEY_EPS then
					crossings[#crossings + 1] = a.x
				end
			end
		end
		table.sort(crossings)
		intervals[zi] = {}
		for crossIndex = 1, #crossings, 2 do
			local x1 = crossings[crossIndex]
			local x2 = crossings[crossIndex + 1]
			if x1 and x2 and x2 - x1 > KEY_EPS then
				intervals[zi][#intervals[zi] + 1] = { x1, x2 }
			end
		end
	end
	return intervals
end

local function buildInsideGrid(xs, zs, rowIntervals)
	local inside = {}
	for zi = 1, #zs - 1 do
		inside[zi] = {}
		for xi = 1, #xs - 1 do
			local xMid = (xs[xi] + xs[xi + 1]) * 0.5
			local filled = false
			for _, interval in ipairs(rowIntervals[zi]) do
				if xMid > interval[1] + KEY_EPS and xMid < interval[2] - KEY_EPS then
					filled = true
					break
				end
			end
			inside[zi][xi] = filled
		end
	end
	return inside
end

local function enumerateMaximalRectangles(xs, zs, inside)
	local candidates = {}
	for topRow = 1, #zs - 1 do
		local active = {}
		for xi = 1, #xs - 1 do
			active[xi] = true
		end
		for bottomRow = topRow, #zs - 1 do
			for xi = 1, #xs - 1 do
				active[xi] = active[xi] and inside[bottomRow][xi]
			end
			local xi = 1
			while xi <= #xs - 1 do
				if active[xi] then
					local startXi = xi
					while xi <= #xs - 1 and active[xi] do
						xi += 1
					end
					candidates[#candidates + 1] = {
						x1i = startXi,
						x2i = xi,
						z1i = topRow,
						z2i = bottomRow + 1,
						x1 = xs[startXi],
						x2 = xs[xi],
						z1 = zs[topRow],
						z2 = zs[bottomRow + 1],
					}
				else
					xi += 1
				end
			end
		end
	end

	for _, rect in ipairs(candidates) do
		rect.width = rect.x2 - rect.x1
		rect.height = rect.z2 - rect.z1
		rect.area = rect.width * rect.height
		rect.cx = (rect.x1 + rect.x2) * 0.5
		rect.cz = (rect.z1 + rect.z2) * 0.5
	end

	local maximal = {}
	for i, rect in ipairs(candidates) do
		local contained = false
		for j, other in ipairs(candidates) do
			if i ~= j
				and rect.x1i >= other.x1i and rect.x2i <= other.x2i
				and rect.z1i >= other.z1i and rect.z2i <= other.z2i
				and (rect.x1i ~= other.x1i or rect.x2i ~= other.x2i or rect.z1i ~= other.z1i or rect.z2i ~= other.z2i)
			then
				contained = true
				break
			end
		end
		if not contained then
			maximal[#maximal + 1] = rect
		end
	end

	return maximal
end

local function countUncoveredArea(rect, uncovered, xs, zs)
	local area = 0
	for zi = rect.z1i, rect.z2i - 1 do
		for xi = rect.x1i, rect.x2i - 1 do
			if uncovered[zi][xi] then
				area += (xs[xi + 1] - xs[xi]) * (zs[zi + 1] - zs[zi])
			end
		end
	end
	return area
end

local function markCovered(rect, uncovered)
	for zi = rect.z1i, rect.z2i - 1 do
		for xi = rect.x1i, rect.x2i - 1 do
			uncovered[zi][xi] = false
		end
	end
end

local function anyUncovered(uncovered)
	for _, row in ipairs(uncovered) do
		for _, cell in ipairs(row) do
			if cell then
				return true
			end
		end
	end
	return false
end

local function selectRectangles(xs, zs, inside, candidates)
	local uncovered = {}
	for zi = 1, #inside do
		uncovered[zi] = {}
		for xi = 1, #inside[zi] do
			uncovered[zi][xi] = inside[zi][xi]
		end
	end

	table.sort(candidates, function(a, b)
		if not approx(a.area, b.area, KEY_EPS) then
			return a.area > b.area
		end
		local aMajor = math.max(a.width, a.height)
		local bMajor = math.max(b.width, b.height)
		if not approx(aMajor, bMajor, KEY_EPS) then
			return aMajor > bMajor
		end
		return a.width + a.height > b.width + b.height
	end)

	local selected = {}
	while anyUncovered(uncovered) do
		local bestRect = nil
		local bestGain = 0
		for _, rect in ipairs(candidates) do
			local gain = countUncoveredArea(rect, uncovered, xs, zs)
			if gain > bestGain + KEY_EPS then
				bestGain = gain
				bestRect = rect
			end
		end
		if not bestRect then
			break
		end
		selected[#selected + 1] = bestRect
		markCovered(bestRect, uncovered)
	end

	return selected
end

local function makeSegment(a, b)
	if samePoint(a, b, KEY_EPS) then
		return nil
	end
	local startPoint = clonePoint(a)
	local endPoint = clonePoint(b)
	if approx(startPoint.z, endPoint.z, KEY_EPS) and startPoint.x > endPoint.x then
		startPoint, endPoint = endPoint, startPoint
	elseif approx(startPoint.x, endPoint.x, KEY_EPS) and startPoint.z > endPoint.z then
		startPoint, endPoint = endPoint, startPoint
	end
	return {
		start = startPoint,
		["end"] = endPoint,
	}
end

local function segmentOrientation(segment)
	if approx(segment.start.z, segment["end"].z, KEY_EPS) then
		return "H"
	end
	return "V"
end

local function buildCenterline(rect)
	if rect.width >= rect.height then
		return makeSegment(v2(rect.x1, rect.cz), v2(rect.x2, rect.cz))
	end
	return makeSegment(v2(rect.cx, rect.z1), v2(rect.cx, rect.z2))
end

local function mergeSegments(segments)
	local buckets = {}
	for _, segment in ipairs(segments) do
		if segment then
			local orientation = segmentOrientation(segment)
			local key = orientation .. ":" .. coordKey(orientation == "H" and segment.start.z or segment.start.x)
			buckets[key] = buckets[key] or { orientation = orientation, coord = orientation == "H" and segment.start.z or segment.start.x, items = {} }
			buckets[key].items[#buckets[key].items + 1] = {
				startValue = orientation == "H" and math.min(segment.start.x, segment["end"].x) or math.min(segment.start.z, segment["end"].z),
				endValue = orientation == "H" and math.max(segment.start.x, segment["end"].x) or math.max(segment.start.z, segment["end"].z),
			}
		end
	end

	local merged = {}
	for _, bucket in pairs(buckets) do
		table.sort(bucket.items, function(a, b)
			if approx(a.startValue, b.startValue, KEY_EPS) then
				return a.endValue < b.endValue
			end
			return a.startValue < b.startValue
		end)
		local current = nil
		for _, item in ipairs(bucket.items) do
			if not current then
				current = { startValue = item.startValue, endValue = item.endValue }
			elseif item.startValue <= current.endValue + KEY_EPS then
				current.endValue = math.max(current.endValue, item.endValue)
			else
				if bucket.orientation == "H" then
					merged[#merged + 1] = makeSegment(v2(current.startValue, bucket.coord), v2(current.endValue, bucket.coord))
				else
					merged[#merged + 1] = makeSegment(v2(bucket.coord, current.startValue), v2(bucket.coord, current.endValue))
				end
				current = { startValue = item.startValue, endValue = item.endValue }
			end
		end
		if current then
			if bucket.orientation == "H" then
				merged[#merged + 1] = makeSegment(v2(current.startValue, bucket.coord), v2(current.endValue, bucket.coord))
			else
				merged[#merged + 1] = makeSegment(v2(bucket.coord, current.startValue), v2(bucket.coord, current.endValue))
			end
		end
	end

	local result = {}
	for _, segment in ipairs(merged) do
		if segment then
			result[#result + 1] = segment
		end
	end
	return result
end

local function pointInsideRect(point, rect)
	return point.x >= rect.x1 - KEY_EPS and point.x <= rect.x2 + KEY_EPS and point.z >= rect.z1 - KEY_EPS and point.z <= rect.z2 + KEY_EPS
end

local function pointInsideAccepted(point, acceptedRects)
	for _, rect in ipairs(acceptedRects) do
		if pointInsideRect(point, rect) then
			return true
		end
	end
	return false
end

local function midpoint(a, b)
	return v2((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)
end

local function segmentInsidePolygon(segment, rowIntervals)
	if segmentOrientation(segment) == "H" then
		local z = segment.start.z
		for zi, intervals in ipairs(rowIntervals) do
			local dummy = zi
			if dummy then
			end
		end
		return true
	end
	return true
end
local function segmentAlreadyCovered(candidate, spineSegments)
	local orientation = segmentOrientation(candidate)
	for _, spine in ipairs(spineSegments) do
		if segmentOrientation(spine) == orientation then
			-- Same orientation: check same axis coordinate and overlapping range
			if orientation == "H" then
				if not approx(spine.start.z, candidate.start.z, KEY_EPS) then continue end
				local sMin = math.min(spine.start.x, spine["end"].x)
				local sMax = math.max(spine.start.x, spine["end"].x)
				local cMin = math.min(candidate.start.x, candidate["end"].x)
				local cMax = math.max(candidate.start.x, candidate["end"].x)
				if cMin >= sMin - KEY_EPS and cMax <= sMax + KEY_EPS then
					return true
				end
			else
				if not approx(spine.start.x, candidate.start.x, KEY_EPS) then continue end
				local sMin = math.min(spine.start.z, spine["end"].z)
				local sMax = math.max(spine.start.z, spine["end"].z)
				local cMin = math.min(candidate.start.z, candidate["end"].z)
				local cMax = math.max(candidate.start.z, candidate["end"].z)
				if cMin >= sMin - KEY_EPS and cMax <= sMax + KEY_EPS then
					return true
				end
			end
		end
	end
	return false
end
local function clipAgainstSpine(candidate, spineSegments, acceptedRects)
	if not candidate then
		return {}
	end

	local orientation = segmentOrientation(candidate)
	local cutValues = { orientation == "H" and candidate.start.x or candidate.start.z, orientation == "H" and candidate["end"].x or candidate["end"].z }
	local intersections = {}

	for _, spine in ipairs(spineSegments) do
		if segmentOrientation(spine) ~= orientation then
			if orientation == "H" then
				local x = spine.start.x
				local z = candidate.start.z
				local withinCandidate = x >= math.min(candidate.start.x, candidate["end"].x) - KEY_EPS and x <= math.max(candidate.start.x, candidate["end"].x) + KEY_EPS
				local withinSpine = z >= math.min(spine.start.z, spine["end"].z) - KEY_EPS and z <= math.max(spine.start.z, spine["end"].z) + KEY_EPS
				if withinCandidate and withinSpine then
					intersections[#intersections + 1] = { point = v2(x, z), value = x }
					cutValues[#cutValues + 1] = x
				end
			else
				local x = candidate.start.x
				local z = spine.start.z
				local withinCandidate = z >= math.min(candidate.start.z, candidate["end"].z) - KEY_EPS and z <= math.max(candidate.start.z, candidate["end"].z) + KEY_EPS
				local withinSpine = x >= math.min(spine.start.x, spine["end"].x) - KEY_EPS and x <= math.max(spine.start.x, spine["end"].x) + KEY_EPS
				if withinCandidate and withinSpine then
					intersections[#intersections + 1] = { point = v2(x, z), value = z }
					cutValues[#cutValues + 1] = z
				end
			end
		end
	end
	
	-- FIX 1: Check start, end, and mid instead of just mid
	--if #intersections == 0 then
	--	local mid = midpoint(candidate.start, candidate["end"])
	--	local aIn = pointInsideAccepted(candidate.start, acceptedRects)
	--	local bIn = pointInsideAccepted(candidate["end"], acceptedRects)
	--	local midIn = pointInsideAccepted(mid, acceptedRects)

	--	if aIn and bIn and midIn then
	--		return {}
	--	end
	--	return { candidate }
	--end
	if #intersections == 0 then
		if segmentAlreadyCovered(candidate, spineSegments) then
			return {}
		end
		return { candidate }
	end
	table.sort(cutValues)
	local deduped = {}
	for _, value in ipairs(cutValues) do
		if #deduped == 0 or not approx(deduped[#deduped], value, KEY_EPS) then
			deduped[#deduped + 1] = value
		end
	end

	local pieces = {}
	for i = 1, #deduped - 1 do
		local aValue = deduped[i]
		local bValue = deduped[i + 1]
		if bValue - aValue > KEY_EPS then
			local aPoint
			local bPoint
			if orientation == "H" then
				aPoint = v2(aValue, candidate.start.z)
				bPoint = v2(bValue, candidate.start.z)
			else
				aPoint = v2(candidate.start.x, aValue)
				bPoint = v2(candidate.start.x, bValue)
			end

			-- FIX 2: Check start, end, and mid to prevent short protrusions from being deleted
			--local mid = midpoint(aPoint, bPoint)
			--local aIn = pointInsideAccepted(aPoint, acceptedRects)
			--local bIn = pointInsideAccepted(bPoint, acceptedRects)
			--local midIn = pointInsideAccepted(mid, acceptedRects)
			local piece = makeSegment(aPoint, bPoint)
			if piece and not segmentAlreadyCovered(piece, spineSegments) then
				pieces[#pieces + 1] = piece
			end
			-- If ANY part of the piece is outside the accepted rects, we keep it
			--if not (aIn and bIn and midIn) then
			--	local piece = makeSegment(aPoint, bPoint)
			--	if piece then
			--		pieces[#pieces + 1] = piece
			--	end
			--end
		end
	end

	return pieces
end


local function buildSpine(rectangles)
	if #rectangles == 0 then
		return {}
	end

	local segments = {}
	local acceptedRects = {}
	local seen = {}
	for index, rect in ipairs(rectangles) do
		local centerline = buildCenterline(rect)
		local additions
		if index == 1 then
			additions = centerline and { centerline } or {}
		else
			additions = clipAgainstSpine(centerline, segments)
		end
		for _, segment in ipairs(additions) do
			local key = segmentKey(segment.start, segment["end"])
			if not seen[key] then
				seen[key] = true
				segments[#segments + 1] = segment
			end
		end
		acceptedRects[#acceptedRects + 1] = rect
		segments = mergeSegments(segments)
	end
	return mergeSegments(segments)
end

function StraightSkeleton.compute(polygon, roofType)
	roofType = roofType or "Hip"

	local cleaned, err = sanitizePolygon(polygon)
	if not cleaned then
		return nil, err
	end

	local xs = {}
	local zs = {}
	for _, point in ipairs(cleaned) do
		xs[#xs + 1] = point.x
		zs[#zs + 1] = point.z
	end
	xs = uniqueSorted(xs)
	zs = uniqueSorted(zs)

	local rowIntervals = buildRowIntervals(cleaned, xs, zs)
	local inside = buildInsideGrid(xs, zs, rowIntervals)
	local candidates = enumerateMaximalRectangles(xs, zs, inside)
	local rectangles = selectRectangles(xs, zs, inside, candidates)
	if #rectangles == 0 then
		return nil, "Only orthogonal polygons allowed."
	end

	local ridges = buildSpine(rectangles)

	return {
		polygon = cleaned,
		ridges = ridges,
		arcs = ridges,
		rectangles = rectangles,
		skeletonArcs = ridges,
		roofType = roofType,
	}
end

return StraightSkeleton