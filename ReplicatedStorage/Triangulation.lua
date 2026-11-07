--[[
	Triangulation

	Turns a folder of wall parts into a 2D floor polygon on the XZ plane and
	triangulates it. Handy for generating floors/ceilings, checking if a point
	is inside a room, getting spawn areas, etc.

	All 2D math here works on plain tables {x = number, z = number}, not
	Vector2/Vector3. Y is ignored everywhere except the debug renderers.

	Typical use:

		local Triangulation = require(path.to.Triangulation)
		local room = Triangulation.fromWalls(workspace.Room.Walls)
		if room then
			print(room.area, #room.triangles)
			Triangulation.debugRender(room.polygon)
			Triangulation.debugRenderTriangles(room.polygon, room.triangles)
		end

	fromWalls() returns:
		polygon      - outer boundary, counter-clockwise, list of {x, z}
		triangles    - list of {i, j, k} indices into polygon
		area         - area of the polygon (studs^2)
		centroid     - average of the vertices (not the true area centroid)
		aabb         - {minX, maxX, minZ, maxZ}
		edgeNormals  - per-edge {a, b, normal, midpoint}, normals face outward

	Assumptions about the walls:
		- Each wall is a BasePart whose length runs along its local X axis.
		- Wall ends that are within WALL_SNAP studs of each other count as
		  the same corner. Bump snapTol up if your walls don't quite meet.
		- If a closed boundary can't be found, we fall back to the bounding
		  box of all wall endpoints so callers always get *something*.

	Winding: "counter-clockwise" here means signedArea() > 0 using
	x * z' - x' * z. Everything that cares about orientation calls
	ensureCCW() first, so you can pass polygons in either order.
]]

local Triangulation = {}

-- General float tolerance for cross products, determinants etc.
local EPSILON = 1e-6
-- Default distance (studs) under which two wall endpoints are merged.
local WALL_SNAP = 0.5

---------------------------------------------------------------------------
-- Small 2D vector helpers (x/z)
---------------------------------------------------------------------------

local function v2(x, z)
	return {x = x, z = z}
end

local function v2Sub(a, b)
	return v2(a.x - b.x, a.z - b.z)
end

local function v2Add(a, b)
	return v2(a.x + b.x, a.z + b.z)
end

local function v2Scale(a, s)
	return v2(a.x * s, a.z * s)
end

local function v2Dot(a, b)
	return a.x * b.x + a.z * b.z
end

-- 2D cross product (z-component of the 3D cross). Positive means b is
-- counter-clockwise from a.
local function v2Cross(a, b)
	return a.x * b.z - a.z * b.x
end

local function v2Len(a)
	return math.sqrt(a.x * a.x + a.z * a.z)
end

-- Returns a zero vector instead of NaNs for zero-length input.
local function v2Normalize(a)
	local len = v2Len(a)
	if len < EPSILON then return v2(0, 0) end
	return v2(a.x / len, a.z / len)
end

-- Loose equality check, defaults to the wall snap distance.
local function v2Eq(a, b, tol)
	tol = tol or WALL_SNAP
	return math.abs(a.x - b.x) < tol and math.abs(a.z - b.z) < tol
end

-- Exposed so other modules can reuse the same vector format.
Triangulation.v2 = v2
Triangulation.v2Sub = v2Sub
Triangulation.v2Add = v2Add
Triangulation.v2Scale = v2Scale
Triangulation.v2Dot = v2Dot
Triangulation.v2Cross = v2Cross
Triangulation.v2Len = v2Len
Triangulation.v2Normalize = v2Normalize
Triangulation.v2Eq = v2Eq

---------------------------------------------------------------------------
-- Basic polygon info
---------------------------------------------------------------------------

-- Shoelace formula. Sign tells you the winding (positive = CCW).
function Triangulation.signedArea(poly)
	local sum = 0
	local n = #poly
	for i = 1, n do
		local j = (i % n) + 1
		sum += poly[i].x * poly[j].z - poly[j].x * poly[i].z
	end
	return sum / 2
end

function Triangulation.area(poly)
	return math.abs(Triangulation.signedArea(poly))
end

function Triangulation.isCounterClockwise(poly)
	return Triangulation.signedArea(poly) > 0
end

-- Returns a reversed copy if the polygon is clockwise, otherwise the
-- same table (not a copy).
function Triangulation.ensureCCW(poly)
	if not Triangulation.isCounterClockwise(poly) then
		local reversed = {}
		for i = #poly, 1, -1 do
			table.insert(reversed, poly[i])
		end
		return reversed
	end
	return poly
end

-- Vertex average. Good enough for labels/camera targets, but for very
-- uneven vertex spacing it won't match the real center of mass.
function Triangulation.centroid(poly)
	local cx, cz = 0, 0
	local n = #poly
	for i = 1, n do
		cx += poly[i].x
		cz += poly[i].z
	end
	return v2(cx / n, cz / n)
end

---------------------------------------------------------------------------
-- Geometry tests used by the ear clipper
---------------------------------------------------------------------------

-- Barycentric point-in-triangle test. Points on the edges count as inside
-- (within EPSILON), which is what we want for rejecting ears.
local function pointInTriangle(p, a, b, c)
	local v0 = v2Sub(c, a)
	local v1 = v2Sub(b, a)
	local v2p = v2Sub(p, a)

	local dot00 = v2Dot(v0, v0)
	local dot01 = v2Dot(v0, v1)
	local dot02 = v2Dot(v0, v2p)
	local dot11 = v2Dot(v1, v1)
	local dot12 = v2Dot(v1, v2p)

	-- Degenerate (flat) triangle, nothing can be inside it.
	local inv = dot00 * dot11 - dot01 * dot01
	if math.abs(inv) < EPSILON then return false end
	inv = 1 / inv

	local u = (dot11 * dot02 - dot01 * dot12) * inv
	local v = (dot00 * dot12 - dot01 * dot02) * inv

	return u >= -EPSILON and v >= -EPSILON and (u + v) <= 1 + EPSILON
end

-- True only for a proper crossing in the middle of both segments.
-- Touching at endpoints and parallel/collinear segments return false.
local function segmentsIntersect(p1, p2, p3, p4)
	local d1 = v2Sub(p2, p1)
	local d2 = v2Sub(p4, p3)
	local cross = v2Cross(d1, d2)
	if math.abs(cross) < EPSILON then return false end

	local d3 = v2Sub(p3, p1)
	local t = v2Cross(d3, d2) / cross
	local u = v2Cross(d3, d1) / cross

	return t > EPSILON and t < (1 - EPSILON) and u > EPSILON and u < (1 - EPSILON)
end

---------------------------------------------------------------------------
-- Ear clipping
---------------------------------------------------------------------------

-- Triangulates a simple polygon (no holes, no self intersections).
-- Returns a list of {i, j, k} index triples into the CCW version of poly.
--
-- Note: if poly was clockwise, the indices refer to the reversed polygon,
-- not the one you passed in. fromWalls() avoids this by passing an
-- already-CCW polygon.
--
-- O(n^3) worst case, which is fine for room outlines but not for
-- huge meshes.
function Triangulation.triangulate(poly)
	local n = #poly
	if n < 3 then return {} end
	if n == 3 then return {{1, 2, 3}} end

	poly = Triangulation.ensureCCW(poly)

	-- Vertices still left to clip. We remove from this list, not from poly,
	-- so the output indices stay valid.
	local indices = {}
	for i = 1, n do indices[i] = i end

	-- Is the corner at position idx (in `indices`) convex? With CCW winding
	-- a left turn (positive cross) means convex.
	local function isConvex(idx)
		local count = #indices
		local prev = indices[((idx - 2) % count) + 1]
		local curr = indices[((idx - 1) % count) + 1]
		local next = indices[(idx % count) + 1]
		local edge1 = v2Sub(poly[curr], poly[prev])
		local edge2 = v2Sub(poly[next], poly[curr])
		return v2Cross(edge1, edge2) > EPSILON
	end

	-- Can we cut off the triangle (prev, curr, next)? It must not contain any
	-- other remaining vertex, and the new diagonal prev->next must not cross
	-- any remaining edge.
	local function isDiagonalInside(idx)
		local count = #indices
		local prevIdx = ((idx - 2) % count) + 1
		local currIdx = ((idx - 1) % count) + 1
		local nextIdx = (idx % count) + 1
		local prev = indices[prevIdx]
		local curr = indices[currIdx]
		local next = indices[nextIdx]

		for j = 1, count do
			if j == prevIdx or j == currIdx or j == nextIdx then continue end
			local pt = poly[indices[j]]
			if pointInTriangle(pt, poly[prev], poly[curr], poly[next]) then
				return false
			end
		end

		local pA = poly[prev]
		local pC = poly[next]
		for j = 1, count do
			local jNext = (j % count) + 1
			local eA = poly[indices[j]]
			local eB = poly[indices[jNext]]
			-- Edges sharing an endpoint with the diagonal always "touch" it,
			-- so skip them.
			if indices[j] == prev or indices[j] == next or indices[jNext] == prev or indices[jNext] == next then
				continue
			end
			if segmentsIntersect(pA, pC, eA, eB) then
				return false
			end
		end

		return true
	end

	local triangles = {}
	local safety = 0
	local maxIter = n * n

	-- Clip one ear per pass until only a triangle is left.
	while #indices > 3 and safety < maxIter do
		safety += 1
		local earFound = false
		local count = #indices

		for i = 1, count do
			if isConvex(i) and isDiagonalInside(i) then
				local prevIdx = ((i - 2) % count) + 1
				local currIdx = ((i - 1) % count) + 1
				local nextIdx = (i % count) + 1
				table.insert(triangles, {
					indices[prevIdx],
					indices[currIdx],
					indices[nextIdx]
				})
				table.remove(indices, currIdx)
				earFound = true
				break
			end
		end

		-- Usually means duplicate/collinear points or a self-intersecting
		-- outline. We return whatever we managed to clip.
		if not earFound then
			warn("[Triangulation] No ear found with " .. #indices .. " vertices remaining — polygon may be degenerate")
			break
		end
	end

	if #indices == 3 then
		table.insert(triangles, {indices[1], indices[2], indices[3]})
	end

	return triangles
end

---------------------------------------------------------------------------
-- Edges / bounds
---------------------------------------------------------------------------

-- One entry per edge with its outward-facing unit normal and midpoint.
-- For a CCW polygon, rotating the edge direction clockwise (z, -x)
-- points away from the interior.
function Triangulation.edgeNormals(poly)
	poly = Triangulation.ensureCCW(poly)
	local normals = {}
	local n = #poly
	for i = 1, n do
		local j = (i % n) + 1
		local edge = v2Sub(poly[j], poly[i])
		local outward = v2Normalize(v2(edge.z, -edge.x))
		table.insert(normals, {
			a = poly[i],
			b = poly[j],
			normal = outward,
			midpoint = v2Scale(v2Add(poly[i], poly[j]), 0.5),
		})
	end
	return normals
end

function Triangulation.aabb(poly)
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, p in ipairs(poly) do
		if p.x < minX then minX = p.x end
		if p.x > maxX then maxX = p.x end
		if p.z < minZ then minZ = p.z end
		if p.z > maxZ then maxZ = p.z end
	end
	return {minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ}
end

---------------------------------------------------------------------------
-- Walls -> boundary polygon
---------------------------------------------------------------------------

-- Converts each wall part into a 2D segment between its two ends.
-- The wall's length is assumed to be its Size.X, so rotate walls with
-- that in mind. Thickness and height are ignored.
function Triangulation.extractWallSegments(wallsFolder)
	local segments = {}
	for _, wall in ipairs(wallsFolder:GetChildren()) do
		if not wall:IsA("BasePart") then continue end
		local cf = wall.CFrame
		local halfX = wall.Size.X / 2
		local endA = cf * Vector3.new(halfX, 0, 0)
		local endB = cf * Vector3.new(-halfX, 0, 0)
		table.insert(segments, {
			a = v2(endA.X, endA.Z),
			b = v2(endB.X, endB.Z),
			part = wall,
		})
	end
	return segments
end

-- Groups endpoints that are within `tolerance` of each other and moves
-- them all to the group's average. This fixes walls that overlap or stop
-- slightly short at corners.
--
-- Heads up: this edits the points inside `segments` in place.
-- Clustering is greedy (first point found becomes the anchor), which is
-- fine as long as real corners are further apart than the tolerance.
local function snapEndpoints(segments, tolerance)
	tolerance = tolerance or WALL_SNAP
	local allPts = {}
	for _, seg in ipairs(segments) do
		table.insert(allPts, seg.a)
		table.insert(allPts, seg.b)
	end

	local clusters = {}
	local assigned = {}

	for i, pt in ipairs(allPts) do
		if assigned[i] then continue end
		local cluster = {pt}
		assigned[i] = true
		for j = i + 1, #allPts do
			if not assigned[j] and v2Eq(pt, allPts[j], tolerance) then
				table.insert(cluster, allPts[j])
				assigned[j] = true
			end
		end
		local cx, cz = 0, 0
		for _, p in ipairs(cluster) do
			cx += p.x
			cz += p.z
		end
		local avg = v2(cx / #cluster, cz / #cluster)
		for _, p in ipairs(cluster) do
			p.x = avg.x
			p.z = avg.z
		end
		table.insert(clusters, avg)
	end

	return clusters
end

-- Builds an undirected graph from the (snapped) segments.
-- Nodes are keyed by their coordinates rounded to 2 decimals, so snapped
-- points that are basically equal end up as the same node.
--
-- Returns: nodeMap[key] = {pt = {x, z}, neighbors = {[key] = node}}
local function buildGraph(segments, snapTol)
	snapEndpoints(segments, snapTol)

	local nodeMap = {}
	local function key(pt) return string.format("%.2f,%.2f", pt.x, pt.z) end

	local function getOrAdd(pt)
		local k = key(pt)
		if not nodeMap[k] then
			nodeMap[k] = {pt = pt, neighbors = {}}
		end
		return nodeMap[k]
	end

	for _, seg in ipairs(segments) do
		local nA = getOrAdd(seg.a)
		local nB = getOrAdd(seg.b)
		local kA = key(seg.a)
		local kB = key(seg.b)
		-- Skip walls that collapsed to a single point after snapping.
		if kA ~= kB then
			nA.neighbors[kB] = nB
			nB.neighbors[kA] = nA
		end
	end

	return nodeMap
end

-- Finds the outer outline of the walls.
--
-- How it works: treat the walls as a planar graph and walk every face.
-- At each node we sort neighbours by angle, and when we arrive along an
-- edge we leave by the next edge in clockwise order. Following that rule
-- traces closed loops (faces). Every directed edge belongs to exactly one
-- face, so we mark them as visited and don't trace the same loop twice.
--
-- Of all the loops found, we keep the one with the largest positive
-- signed area, which for a normal set of walls is the outer boundary.
-- Interior walls just split the inside into smaller faces that lose.
--
-- Returns a CCW polygon, or {} if nothing closed was found.
function Triangulation.extractOuterBoundary(segments, snapTol)
	if #segments == 0 then return {} end

	snapTol = snapTol or WALL_SNAP
	local graph = buildGraph(segments, snapTol)
	local directedVisited = {}

	-- Must match the key format used in buildGraph.
	local function key(pt)
		return string.format("%.2f,%.2f", pt.x, pt.z)
	end

	local function directedKey(fromKey, toKey)
		return fromKey .. "->" .. toKey
	end

	local function angle(fromPt, toPt)
		return math.atan2(toPt.z - fromPt.z, toPt.x - fromPt.x)
	end

	-- Precompute each node's neighbours sorted by angle (counter-clockwise).
	local sortedNeighbors = {}
	for nodeKey, node in pairs(graph) do
		local neighbors = {}
		for neighborKey, neighbor in pairs(node.neighbors) do
			table.insert(neighbors, {
				key = neighborKey,
				angle = angle(node.pt, neighbor.pt),
			})
		end
		table.sort(neighbors, function(a, b)
			return a.angle < b.angle
		end)
		sortedNeighbors[nodeKey] = neighbors
	end

	-- Walks one face starting with the directed edge startKey -> nextKey.
	-- Returns the face's points, or nil if the walk hits a dead end or
	-- doesn't close.
	local function traceFace(startKey, nextKey)
		local face = {}
		local currentKey = startKey
		local neighborKey = nextKey
		local safety = 0
		local maxSteps = math.max(#segments * 8, 32)

		while safety < maxSteps do
			safety += 1
			directedVisited[directedKey(currentKey, neighborKey)] = true
			table.insert(face, graph[currentKey].pt)

			local around = sortedNeighbors[neighborKey]
			if not around or #around == 0 then
				return nil
			end

			-- Find the edge we came in on, as seen from the next node...
			local incomingIndex = nil
			for i, entry in ipairs(around) do
				if entry.key == currentKey then
					incomingIndex = i
					break
				end
			end
			if not incomingIndex then
				return nil
			end

			-- ...and take the one just before it (next one clockwise).
			-- At a dead-end wall this wraps back to the same edge, so the
			-- walk goes around the end and back down the other side.
			local nextIndex = incomingIndex - 1
			if nextIndex < 1 then
				nextIndex = #around
			end

			local newCurrent = neighborKey
			local newNeighbor = around[nextIndex].key
			-- Back at the starting edge, loop is closed.
			if newCurrent == startKey and newNeighbor == nextKey then
				break
			end
			currentKey = newCurrent
			neighborKey = newNeighbor
		end

		if #face < 3 then
			return nil
		end

		-- Drop consecutive duplicates (and a duplicated closing point).
		local cleaned = {}
		for _, pt in ipairs(face) do
			if #cleaned == 0 or not v2Eq(cleaned[#cleaned], pt, snapTol * 0.5) then
				table.insert(cleaned, pt)
			end
		end
		if #cleaned >= 2 and v2Eq(cleaned[1], cleaned[#cleaned], snapTol * 0.5) then
			table.remove(cleaned, #cleaned)
		end
		if #cleaned < 3 then
			return nil
		end

		-- Remove points in the middle of straight runs (e.g. where two
		-- walls meet end to end along the same line).
		return Triangulation.simplify(cleaned)
	end

	-- Try every directed edge not already used by a traced face, keep the
	-- biggest CCW loop.
	local bestFace = nil
	local bestArea = 0
	for fromKey, node in pairs(graph) do
		for toKey in pairs(node.neighbors) do
			local dKey = directedKey(fromKey, toKey)
			if not directedVisited[dKey] then
				local face = traceFace(fromKey, toKey)
				if face and #face >= 3 then
					local area = Triangulation.signedArea(face)
					if area > bestArea + EPSILON then
						bestArea = area
						bestFace = face
					end
				end
			end
		end
	end

	if not bestFace then
		warn("[Triangulation] Failed to extract outer boundary from wall graph")
		return {}
	end

	return Triangulation.ensureCCW(bestFace)
end

-- Main entry point. Give it a folder of wall parts and get back the room
-- outline, its triangulation and a few handy extras (see the top of the
-- file). Returns nil if the folder has no BaseParts.
--
-- snapTol is optional, defaults to WALL_SNAP.
function Triangulation.fromWalls(wallsFolder, snapTol)
	local segments = Triangulation.extractWallSegments(wallsFolder)
	if #segments == 0 then return nil end

	local polygon = Triangulation.extractOuterBoundary(segments, snapTol)

	-- Couldn't find a closed outline (gaps bigger than snapTol, stray walls,
	-- etc). Fall back to a rectangle around all the wall endpoints.
	if #polygon < 3 then
		local aabb = Triangulation.aabb(
			(function()
				local pts = {}
				for _, s in ipairs(segments) do
					table.insert(pts, s.a)
					table.insert(pts, s.b)
				end
				return pts
			end)()
		)
		polygon = {
			v2(aabb.minX, aabb.minZ),
			v2(aabb.maxX, aabb.minZ),
			v2(aabb.maxX, aabb.maxZ),
			v2(aabb.minX, aabb.maxZ),
		}
	end

	polygon = Triangulation.ensureCCW(polygon)
	local tris = Triangulation.triangulate(polygon)

	return {
		polygon = polygon,
		triangles = tris,
		area = Triangulation.area(polygon),
		centroid = Triangulation.centroid(polygon),
		aabb = Triangulation.aabb(polygon),
		edgeNormals = Triangulation.edgeNormals(polygon),
	}
end

---------------------------------------------------------------------------
-- Misc polygon utilities
---------------------------------------------------------------------------

-- Even-odd ray cast along +X. Works for any winding. Points exactly on an
-- edge can go either way.
function Triangulation.pointInPolygon(poly, pt)
	local inside = false
	local n = #poly
	local j = n
	for i = 1, n do
		local pi = poly[i]
		local pj = poly[j]
		-- Only edges that straddle the ray's z can be crossed.
		if (pi.z > pt.z) ~= (pj.z > pt.z) then
			local intersectX = pj.x + (pt.z - pj.z) / (pi.z - pj.z) * (pi.x - pj.x)
			if pt.x < intersectX then
				inside = not inside
			end
		end
		j = i
	end
	return inside
end

-- Moves every vertex along its corner bisector so each edge ends up
-- `dist` studs from where it was.
--   positive dist -> shrinks the polygon (inset, e.g. keep away from walls)
--   negative dist -> grows it
--
-- This is a simple per-vertex offset, not a full polygon offset. Very
-- sharp corners are clamped to 3x dist so they don't shoot off, and large
-- insets on thin shapes can make the result self-intersect.
function Triangulation.offsetPolygon(poly, dist)
	poly = Triangulation.ensureCCW(poly)
	local n = #poly
	if n < 3 then return poly end

	local offsetPts = {}
	for i = 1, n do
		local prev = poly[((i - 2) % n) + 1]
		local curr = poly[i]
		local next = poly[(i % n) + 1]

		-- Directions of the edges coming into and leaving this corner.
		local e1 = v2Normalize(v2Sub(curr, prev))
		local e2 = v2Normalize(v2Sub(next, curr))

		-- Their outward normals, and the direction halfway between them.
		local n1 = v2(e1.z, -e1.x)
		local n2 = v2(e2.z, -e2.x)

		local bisector = v2Normalize(v2Add(n1, n2))
		-- How far along the bisector we need to move so the edges shift by
		-- exactly `dist`. Guard against a zero (180 degree spike).
		local sinHalf = v2Cross(e2, bisector)
		if math.abs(sinHalf) < EPSILON then sinHalf = 1 end

		local offset = dist / sinHalf
		local maxOffset = math.abs(dist) * 3
		offset = math.clamp(offset, -maxOffset, maxOffset)

		table.insert(offsetPts, v2Add(curr, v2Scale(bisector, offset)))
	end

	return offsetPts
end

-- Removes vertices that sit on a straight line between their neighbours.
-- angleTol is compared against the sine of the turn angle (default 0.01,
-- roughly half a degree). Returns the original if simplifying would leave
-- fewer than 3 points.
function Triangulation.simplify(poly, angleTol)
	angleTol = angleTol or 0.01
	local result = {}
	local n = #poly
	for i = 1, n do
		local prev = poly[((i - 2) % n) + 1]
		local curr = poly[i]
		local next = poly[(i % n) + 1]
		local e1 = v2Normalize(v2Sub(curr, prev))
		local e2 = v2Normalize(v2Sub(next, curr))
		local cross = math.abs(v2Cross(e1, e2))
		if cross > angleTol then
			table.insert(result, curr)
		end
	end
	if #result < 3 then return poly end
	return result
end

---------------------------------------------------------------------------
-- Debug drawing
---------------------------------------------------------------------------

-- Draws the polygon outline as neon parts at height y, with a yellow ball
-- on each vertex. Returns the folder so you can :Destroy() it later.
function Triangulation.debugRender(poly, y, parent, color)
	color = color or Color3.fromRGB(0, 255, 100)
	y = y or 5
	parent = parent or workspace

	local folder = Instance.new("Folder")
	folder.Name = "TriDebug"
	folder.Parent = parent

	local n = #poly
	for i = 1, n do
		local j = (i % n) + 1
		local a = Vector3.new(poly[i].x, y, poly[i].z)
		local b = Vector3.new(poly[j].x, y, poly[j].z)
		local mid = (a + b) / 2
		local len = (b - a).Magnitude

		local p = Instance.new("Part")
		p.Name = "Edge_" .. i
		p.Size = Vector3.new(len, 0.3, 0.3)
		-- lookAt points -Z at b; the extra 90 degree turn lines the part's
		-- X axis (its length) up with the edge instead.
		p.CFrame = CFrame.lookAt(mid, b) * CFrame.Angles(0, math.rad(90), 0)
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.Color = color
		p.Material = Enum.Material.Neon
		p.Transparency = 0.2
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = folder

		local dot = Instance.new("Part")
		dot.Name = "Vert_" .. i
		dot.Shape = Enum.PartType.Ball
		dot.Size = Vector3.new(0.6, 0.6, 0.6)
		dot.CFrame = CFrame.new(a)
		dot.Anchored = true
		dot.CanCollide = false
		dot.CanQuery = false
		dot.Color = Color3.fromRGB(255, 255, 0)
		dot.Material = Enum.Material.Neon
		dot.Transparency = 0
		dot.Parent = folder
	end

	return folder
end

-- Draws every triangle's edges as thin neon parts. Drawn slightly above
-- debugRender's default height so the two don't z-fight. Shared edges get
-- drawn twice, which is fine for debugging.
function Triangulation.debugRenderTriangles(poly, tris, y, parent, color)
	color = color or Color3.fromRGB(100, 200, 255)
	y = y or 5.1
	parent = parent or workspace

	local folder = Instance.new("Folder")
	folder.Name = "TriDebugTris"
	folder.Parent = parent

	for ti, tri in ipairs(tris) do
		for ei = 1, 3 do
			local ai = tri[ei]
			local bi = tri[(ei % 3) + 1]
			local a = Vector3.new(poly[ai].x, y, poly[ai].z)
			local b = Vector3.new(poly[bi].x, y, poly[bi].z)
			local mid = (a + b) / 2
			local len = (b - a).Magnitude

			local p = Instance.new("Part")
			p.Name = "Tri" .. ti .. "_E" .. ei
			p.Size = Vector3.new(len, 0.15, 0.15)
			p.CFrame = CFrame.lookAt(mid, b) * CFrame.Angles(0, math.rad(90), 0)
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.Color = color
			p.Material = Enum.Material.Neon
			p.Transparency = 0.4
			p.TopSurface = Enum.SurfaceType.Smooth
			p.BottomSurface = Enum.SurfaceType.Smooth
			p.Parent = folder
		end
	end

	return folder
end

return Triangulation
