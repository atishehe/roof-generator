--[[Doucmentition
    WallDepth — Generate wall segments with variable thickness along the path

    Creates walls where thickness varies smoothly along the length by using
    an offset profile. The wall is centered on the baseline path, with total
    thickness = 2 * offset (symmetric on both sides).

    API:
        WallDepth.createWallSegment(startPos, endPos, height, offsetProfile, options)
            -> Model

        offsetProfile: number | table | function
            - number: constant half-thickness (studs)
            - table: { {position=0-1, offset=num}, ... } piecewise linear samples
            - function(t: number): number where t in [0,1] along segment

        options: table
            - segments: number (default 16, resolution along the segment)
            - wallTemplate: Part (optional template from buildingObjects)
            - parent: Instance (where to parent result Model)
            - color: Color3
            - material: Enum.Material
            - canCollide: boolean (default true)
            - canQuery: boolean (default true)
            - anchored: boolean (default true)
            - locked: boolean (default true)

        Returns Model containing generated wall parts.
]]

local WallDepth = {}

local EPSILON = 1e-6

local function clamp01(t)
    return math.clamp(t, 0, 1)
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

function WallDepth.getOffset(profile, t)
    if type(profile) == "number" then
        return profile
    elseif type(profile) == "table" then
        if #profile == 0 then return 0 end
        if #profile == 1 then return profile[1].offset end
        for i = 1, #profile - 1 do
            local p1 = profile[i]
            local p2 = profile[i + 1]
            if t >= p1.position and t <= p2.position then
                local localT = (t - p1.position) / (p2.position - p1.position)
                return lerp(p1.offset, p2.offset, localT)
            end
        end
        return profile[#profile].offset
    elseif type(profile) == "function" then
        return profile(t)
    else
        return 0
    end
end

function WallDepth.createWallSegment(startPos, endPos, height, offsetProfile, options)
    options = options or {}
    local segments = options.segments or 16
    local wallTemplate = options.wallTemplate
    local parent = options.parent or workspace
    local color = options.color or Color3.fromRGB(200, 200, 200)
    local material = options.material or Enum.Material.SmoothPlastic
    local canCollide = options.canCollide ~= false
    local canQuery = options.canQuery ~= false
    local anchored = options.anchored ~= false
    local locked = options.locked ~= false

    -- Default half-thickness = 0.15 (total 0.3)
    local defaultOffset = 0.15
    local offsetProf = offsetProfile or defaultOffset

    local wallModel = Instance.new("Model")
    wallModel.Name = "WallDepthSegment"
    wallModel.Parent = parent

    local dir = (endPos - startPos)
    local length = dir.Magnitude
    if length < EPSILON then
        warn("[WallDepth] Start and end positions are too close")
        return wallModel
    end
    dir = dir.Unit

    local perp = Vector3.new(-dir.Z, 0, dir.X) 

    local samples = {}
    for i = 0, segments do
        local t = i / segments
        local basePos = startPos + dir * (length * t)
        table.insert(samples, {
            position = basePos,
            t = t,
        })
    end

    for i = 1, #samples - 1 do
        local s1 = samples[i]
        local s2 = samples[i + 1]

        local segmentLength = (s2.position - s1.position).Magnitude
        if segmentLength < EPSILON then continue end

        local tMid = (s1.t + s2.t) / 2
        local halfThick = WallDepth.getOffset(offsetProf, tMid)
        local thickness = 2 * halfThick
        if thickness < 0.05 then thickness = 0.05 end

        local wallPart
        if wallTemplate then
            wallPart = wallTemplate:Clone()
            wallPart.Parent = wallModel
            -- Override size
            wallPart.Size = Vector3.new(segmentLength, height, thickness)
        else
            wallPart = Instance.new("Part")
            wallPart.Parent = wallModel
            wallPart.Size = Vector3.new(segmentLength, height, thickness)
        end

        local segmentDir = (s2.position - s1.position).Unit
        local segmentCenter = (s1.position + s2.position) / 2
        local segmentUp = Vector3.new(0, 1, 0)
        local lookVec = -perp  -- Z axis through thickness

        local cf = CFrame.fromMatrix(
            segmentCenter,
            segmentDir,   
            segmentUp,    
            lookVec       
        )

        wallPart.CFrame = cf
        wallPart.Anchored = anchored
        wallPart.CanCollide = canCollide
        wallPart.CanQuery = canQuery
        wallPart.Locked = locked
        wallPart.Color = color
        wallPart.Material = material
    end

    return wallModel
end

function WallDepth.createUniformWall(startPos, endPos, height, halfThickness, options)
    return WallDepth.createWallSegment(startPos, endPos, height, halfThickness, options)
end

function WallDepth.createProfiledWall(startPos, endPos, height, profile, options)
    return WallDepth.createWallSegment(startPos, endPos, height, profile, options)
end

return WallDepth
