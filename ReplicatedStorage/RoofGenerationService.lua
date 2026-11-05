local RoofGenerator3D = {}

local EPS = 1e-4

local function v3(x, y, z)
	return Vector3.new(x, y, z)
end

local function samePoint(p1, p2)
	return math.abs(p1.x - p2.x) < EPS and math.abs(p1.z - p2.z) < EPS
end

local function isPointOnSegment(p, s1, s2)
	local d1 = math.sqrt((p.x - s1.x)^2 + (p.z - s1.z)^2)
	local d2 = math.sqrt((p.x - s2.x)^2 + (p.z - s2.z)^2)
	local dFull = math.sqrt((s1.x - s2.x)^2 + (s1.z - s2.z)^2)
	return math.abs(d1 + d2 - dFull) < EPS
end

local function isPointOnPolygon(p, polygon)
	for i = 1, #polygon do
		local a = polygon[i]
		local b = polygon[(i % #polygon) + 1]
		if isPointOnSegment(p, a, b) then
			return true
		end
	end
	return false
end

function RoofGenerator3D.generate(skeletonData, baseHeight, roofHeight)
	local polygon = skeletonData.polygon
	local ridges = skeletonData.ridges
	
	local roofModel = Instance.new("Model")
	roofModel.Name = "GeneratedRoof"
	roofModel.Parent = game.Workspace
	
	local color = Color3.fromRGB(255, 100, 50) -- Warm orange/red
	local material = Enum.Material.SmoothPlastic
	
	local function createPart(name, size, cframe, parent)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.CFrame = cframe
		part.Color = color
		part.Material = material
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Anchored = true
		part.Parent = parent
		return part
	end

	local function createWedge(name, size, cframe, parent)
		local wedge = Instance.new("WedgePart")
		wedge.Name = name
		wedge.Size = size
		wedge.CFrame = cframe
		wedge.Color = color
		wedge.Material = material
		wedge.TopSurface = Enum.SurfaceType.Smooth
		wedge.BottomSurface = Enum.SurfaceType.Smooth
		wedge.Anchored = true
		wedge.Parent = parent
		return wedge
	end

	for _, ridge in ipairs(ridges) do
		local r1 = ridge.start
		local r2 = ridge["end"]
		local isHorizontal = math.abs(r1.z - r2.z) < EPS
		
		local wallA, wallB
		local distA, distB = math.huge, math.huge
		
		for i = 1, #polygon do
			local p1 = polygon[i]
			local p2 = polygon[(i % #polygon) + 1]
			local isWallHorizontal = math.abs(p1.z - p2.z) < EPS
			
			if isHorizontal == isWallHorizontal then
				local ridgeMin = isHorizontal and math.min(r1.x, r2.x) or math.min(r1.z, r2.z)
				local ridgeMax = isHorizontal and math.max(r1.x, r2.x) or math.max(r1.z, r2.z)
				local wallMin = isHorizontal and math.min(p1.x, p2.x) or math.min(p1.z, p2.z)
				local wallMax = isHorizontal and math.max(p1.x, p2.x) or math.max(p1.z, p2.z)
				
				local overlap = math.max(0, math.min(ridgeMax, wallMax) - math.max(ridgeMin, wallMin))
				if overlap > EPS then
					local dist = isHorizontal and (p1.z - r1.z) or (p1.x - r1.x)
					if dist > 0 then
						if dist < distA then
							distA = dist
							wallA = {p1, p2}
						end
					elseif dist < 0 then
						if math.abs(dist) < distB then
							distB = math.abs(dist)
							wallB = {p1, p2}
						end
					end
				end
			end
		end

		local ridgeCenter = v3((r1.x + r2.x) * 0.5, baseHeight + roofHeight, (r1.z + r2.z) * 0.5)
		local ridgeLength = math.sqrt((r1.x - r2.x)^2 + (r1.z - r2.z)^2)
		
		local function createSlope(dist, sideFactor)
			if dist == math.huge then return end
			
			local wallCenterZ = isHorizontal and (r1.z + dist * sideFactor) or (r1.z)
			local wallCenterX = isHorizontal and (r1.x) or (r1.x + dist * sideFactor)

			local hyp = math.sqrt(dist^2 + roofHeight^2)
			local angle = math.atan2(roofHeight, dist)
			
			local size = isHorizontal 
				and v3(ridgeLength, 0.2, hyp)
				or v3(hyp, 0.2, ridgeLength)
			
			local offset = dist * 0.5
			local yOffset = roofHeight * 0.5
			
			local pos = isHorizontal
				and v3((r1.x + r2.x) * 0.5, baseHeight + yOffset, r1.z + offset * sideFactor)
				or v3(r1.x + offset * sideFactor, baseHeight + yOffset, (r1.z + r2.z) * 0.5)
					local function createHalfGable(w, sideFactor)
						if w == math.huge then return end
						local size = isHorizontal
							and v3(0.2, roofHeight, w)
							or v3(w, roofHeight, 0.2)
						
						local pos = isHorizontal
							and v3(pt.x, baseHeight + roofHeight * 0.5, pt.z + (w * 0.5) * sideFactor)
							or v3(pt.x + (w * 0.5) * sideFactor, baseHeight + roofHeight * 0.5, pt.z)
						
						local rot
						if isHorizontal then
							rot = CFrame.Angles(0, sideFactor == 1 and math.rad(180) or 0, 0)
						else
							rot = CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(0, sideFactor == 1 and 0 or math.rad(180), 0)
						end
							
						createWedge("GableEnd", size, CFrame.new(pos) * rot, roofModel)
					end
					local centerX = isHorizontal and pt.x or (pt.x + (distA - distB) * 0.5)
					local centerZ = isHorizontal and (pt.z + (distA - distB) * 0.5) or pt.z
					
					local function createHalfGable(w, sideFactor)
						if w == math.huge then return end
						local size = isHorizontal
							and v3(0.2, roofHeight, w)
							or v3(w, roofHeight, 0.2)
						
						local pos = isHorizontal
							and v3(pt.x, baseHeight + roofHeight * 0.5, pt.z + (w * 0.5) * sideFactor)
							or v3(pt.x + (w * 0.5) * sideFactor, baseHeight + roofHeight * 0.5, pt.z)
						
						local rot = isHorizontal
							and CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(0, sideFactor == 1 and 0 or math.rad(180), 0)
							or CFrame.Angles(0, 0, 0) * CFrame.Angles(0, sideFactor == 1 and math.rad(180) or 0, 0)
							
						createWedge("GableEnd", size, CFrame.new(pos) * rot, roofModel)
					end
					
					createHalfGable(distA, 1)
					createHalfGable(distB, -1)
				end
			end
		end
		
		handleGable(r1)
		handleGable(r2)
	end
	
	return roofModel
end

return RoofGenerator3D