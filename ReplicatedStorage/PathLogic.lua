--[[Documentition
    PathLogic — Generate continuous walls along a custom-drawn path

    Takes a list of Vector3 points (the path) and generates a wall
    along that path using WallDepth, with a consistent offset profile
    applied globally along the entire path.

    API:
        PathLogic.createWalls(points, height, offsetProfile, options)
            -> Model

        points: array of Vector3 - the path polyline (must have at least 2 points)
        height: number - wall height
        offsetProfile: number | table | function - passed to WallDepth
        options: table
            - parent: Instance (where to parent result Model)
            - wallTemplate: Part (passed to WallDepth)
            - color: Color3
            - material: Enum.Material
            - canCollide, canQuery, anchored, locked: booleans
            - segmentsPerWall: number (resolution per straight segment, default 16)
            - cornerSmoothing: boolean (not yet implemented)

        Returns Model containing all wall segment parts.
]]

local PathLogic = {}
local WallDepth = require(script.Parent.WallDepth)

local EPSILON = 1e-6

function PathLogic.createWalls(points, height, offsetProfile, options)
    options = options or {}
    local model = Instance.new("Model")
    model.Name = "PathWalls"
    model.Parent = options.parent or workspace

    if #points < 2 then
        warn("[PathLogic] Need at least 2 points to create a path")
        return model
    end

    local segLengths = {}
    local totalLen = 0
    for i = 1, #points - 1 do
        local len = (points[i+1] - points[i]).Magnitude
        segLengths[i] = len
        totalLen = totalLen + len
    end

    if totalLen < EPSILON then
        warn("[PathLogic] Total path length is near zero")
        return model
    end

    local ts = {0}
    local accum = 0
    for i = 1, #segLengths do
        accum = accum + segLengths[i]
        table.insert(ts, accum / totalLen)
    end

    local offsets = {}
    for i = 1, #ts do
        offsets[i] = WallDepth.getOffset(offsetProfile, ts[i])
    end

    local wdOptions = {}
    for k, v in pairs(options) do
        if k ~= "parent" and k ~= "height" and k ~= "offsetProfile" and k ~= "segmentsPerWall" then
            wdOptions[k] = v
        end
    end
    if options.segmentsPerWall then
        wdOptions.segments = options.segmentsPerWall
    end

    for i = 1, #points - 1 do
        local startPt = points[i]
        local endPt = points[i+1]
        local offsetStart = offsets[i]
        local offsetEnd = offsets[i+1]

        local segProfile = {
            {position = 0, offset = offsetStart},
            {position = 1, offset = offsetEnd}
        }

        local segModel = WallDepth.createWallSegment(
            startPt, endPt, height, segProfile, wdOptions
        )
    end

    return model
end

--[[
    Convenience: create a closed loop (polygon) of walls.
    The last point connects back to the first.
]]
function PathLogic.createClosedLoop(points, height, offsetProfile, options)
    if #points < 3 then
        warn("[PathLogic] Closed loop requires at least 3 points")
        return PathLogic.createWalls(points, height, offsetProfile, options)
    end
    -- Append first point to close the loop
    local closedPoints = {}
    for _, p in ipairs(points) do
        table.insert(closedPoints, p)
    end
    table.insert(closedPoints, points[1])
    return PathLogic.createWalls(closedPoints, height, offsetProfile, options)
end

--[[
    Convenience: create a rectangular perimeter from AABB.
    minX, maxX, minZ, maxZ define the rectangle.
    The wall path runs around the perimeter.
]]
function PathLogic.createRectPerimeter(minX, maxX, minZ, maxZ, height, offsetProfile, options)
    local points = {
        Vector3.new(minX, 0, minZ),
        Vector3.new(maxX, 0, minZ),
        Vector3.new(maxX, 0, maxZ),
        Vector3.new(minX, 0, maxZ)
    }
    return PathLogic.createClosedLoop(points, height, offsetProfile, options)
end

return PathLogic
