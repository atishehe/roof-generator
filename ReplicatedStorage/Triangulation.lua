local Triangulation = {}

local EPSILON = 1e-6
local WALL_SNAP = 0.5

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

local function v2Cross(a, b)
	return a.x * b.z - a.z * b.x
end

local function v2Len(a)
	return math.sqrt(a.x * a.x + a.z * a.z)
end

local function v2Normalize(a)
	local len = v2Len(a)
	if len < EPSILON then return v2(0, 0) end
	return v2(a.x / len, a.z / len)
end

local function v2Eq(a, b, tol)
	tol = tol or WALL_SNAP
	return math.abs(a.x - b.x) < tol and math.abs(a.z - b.z) < tol
end

Triangulation.v2 = v2
Triangulation.v2Sub = v2Sub
Triangulation.v2Add = v2Add
Triangulation.v2Scale = v2Scale
Triangulation.v2Dot = v2Dot
Triangulation.v2Cross = v2Cross
Triangulation.v2Len = v2Len
Triangulation.v2Normalize = v2Normalize
Triangulation.v2Eq = v2Eq

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

function Triangulation.centroid(poly)
	local cx, cz = 0, 0
	local n = #poly
	for i = 1, n do
		cx += poly[i].x
		cz += poly[i].z
	end
	return v2(cx / n, cz / n)
end

local function pointInTriangle(p, a, b, c)
	local v0 = v2Sub(c, a)
	local v1 = v2Sub(b, a)
	local v2p = v2Sub(p, a)

	local dot00 = v2Dot(v0, v0)
	local dot01 = v2Dot(v0, v1)
	local dot02 = v2Dot(v0, v2p)
	local dot11 = v2Dot(v1, v1)
	local dot12 = v2Dot(v1, v2p)

	local inv = dot00 * dot11 - dot01 * dot01
	if math.abs(inv) < EPSILON then return false end
	inv = 1 / inv

	local u = (dot11 * dot02 - dot01 * dot12) * inv
	local v = (dot00 * dot12 - dot01 * dot02) * inv

	return u >= -EPSILON and v >= -EPSILON and (u + v) <= 1 + EPSILON
end
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

function Triangulation.triangulate(poly)
	local n = #poly
	if n < 3 then return {} end
	if n == 3 then return {{1, 2, 3}} end

	poly = Triangulation.ensureCCW(poly)

	local indices = {}
	for i = 1, n do indices[i] = i end

	local function isConvex(idx)
		local count = #indices
		local prev = indices[((idx - 2) % count) + 1]
		local curr = indices[((idx - 1) % count) + 1]
		local next = indices[(idx % count) + 1]
		local edge1 = v2Sub(poly[curr], poly[prev])
		local edge2 = v2Sub(poly[next], poly[curr])
		return v2Cross(edge1, edge2) > EPSILON
	end

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
		if kA ~= kB then
			nA.neighbors[kB] = nB
			nB.neighbors[kA] = nA
		end
	end

	return nodeMap
end

function Triangulation.extractOuterBoundary(segments, snapTol)
	if #segments == 0 then return {} end

	snapTol = snapTol or WALL_SNAP
	local graph = buildGraph(segments, snapTol)
	local directedVisited = {}

	local function key(pt)
		return string.format("%.2f,%.2f", pt.x, pt.z)
	end

	local function directedKey(fromKey, toKey)
		return fromKey .. "->" .. toKey
	end

	local function angle(fromPt, toPt)
		return math.atan2(toPt.z - fromPt.z, toPt.x - fromPt.x)
	end

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

			local nextIndex = incomingIndex - 1
			if nextIndex < 1 then
				nextIndex = #around
			end

			local newCurrent = neighborKey
			local newNeighbor = around[nextIndex].key
			if newCurrent == startKey and newNeighbor == nextKey then
				break
			end
			currentKey = newCurrent
			neighborKey = newNeighbor
		end

		if #face < 3 then
			return nil
		end

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

		return Triangulation.simplify(cleaned)
	end

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


function Triangulation.fromWalls(wallsFolder, snapTol)
	local segments = Triangulation.extractWallSegments(wallsFolder)
	if #segments == 0 then return nil end

	local polygon = Triangulation.extractOuterBoundary(segments, snapTol)
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

function Triangulation.pointInPolygon(poly, pt)
	local inside = false
	local n = #poly
	local j = n
	for i = 1, n do
		local pi = poly[i]
		local pj = poly[j]
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

function Triangulation.offsetPolygon(poly, dist)
	poly = Triangulation.ensureCCW(poly)
	local n = #poly
	if n < 3 then return poly end

	local offsetPts = {}
	for i = 1, n do
		local prev = poly[((i - 2) % n) + 1]
		local curr = poly[i]
		local next = poly[(i % n) + 1]

		local e1 = v2Normalize(v2Sub(curr, prev))
		local e2 = v2Normalize(v2Sub(next, curr))

		local n1 = v2(e1.z, -e1.x)
		local n2 = v2(e2.z, -e2.x)

		local bisector = v2Normalize(v2Add(n1, n2))
		local sinHalf = v2Cross(e2, bisector)
		if math.abs(sinHalf) < EPSILON then sinHalf = 1 end

		local offset = dist / sinHalf
		local maxOffset = math.abs(dist) * 3
		offset = math.clamp(offset, -maxOffset, maxOffset)

		table.insert(offsetPts, v2Add(curr, v2Scale(bisector, offset)))
	end

	return offsetPts
end


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
