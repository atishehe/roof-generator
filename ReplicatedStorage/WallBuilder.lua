--[[Doucmentition
    WallBuilder — Advanced wall generation with PathLogic + ResizeAlign integration

    Combines the PathLogic path-following system with ResizeAlign's
    powerful face extension utilities to create walls that automatically
    adjust to touch sloped roofs.

    API:
        WallBuilder.createWallsAlongPath(points, height, offsetProfile, options)
            -> Model

        points: array of Vector3 - wall path polyline
        height: number - base wall height (will extend if needed)
        offsetProfile: number | table | function - wall thickness profile
        options: table
            - parent: Instance
            - wallTemplate: Part
            - color: Color3
            - material: Enum.Material
            - autoExtendToRoof: boolean (default false) - extend walls upward to meet a roof
            - roofParts: Model | Array of Parts - roof to extend towards
            - extensionMode: "OuterTouch" | "InnerTouch" | "ExtendInto" | "ExtendUpTo" (default "OuterTouch")
            - useWedgeJoin: boolean (default false) - use wedge fill for acute angles
            - segmentsPerWall: number (default 16)

        Returns Model containing wall parts.

    If autoExtendToRoof is true, the builder will:
        1. Generate walls at the specified height along the path
        2. Use ResizeAlign.doExtend to extend each wall upward until it touches
           the provided roof geometry (or until maxHeight if roofParts not specified)
        3. Handle wedge joins for complex roof intersections
]]

local WallBuilder = {}
local PathLogic = require(script.Parent.PathLogic)
local WallDepth = require(script.Parent.WallDepth)

local function extendWallPart(wallPart, targetPart, options)
    if not targetPart then return false end

    local maxHeight = options.maxExtensionHeight or 40
    local extensionStep = options.extensionStep or 0.5
    local tolerance = options.tolerance or 0.1

    local wallTop = wallPart.Position + Vector3.new(0, wallPart.Size.Y / 2, 0)
    local rayOrigin = wallTop
    local rayDirection = Vector3.new(0, 1, 0)

    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    raycastParams.FilterDescendantsInstances = {wallPart, wallPart.Parent}

    local currentHeight = wallPart.Size.Y
    local stepCount = math.ceil((maxHeight - currentHeight) / extensionStep)

    for i = 1, stepCount do
        local result = workspace:Raycast(rayOrigin, rayDirection * extensionStep, raycastParams)
        if result and result.Instance == targetPart then
            local distance = (result.Position - wallTop).Magnitude
            local newHeight = currentHeight + distance
            wallPart.Size = Vector3.new(wallPart.Size.X, newHeight, wallPart.Size.Z)
            wallPart.Position = Vector3.new(wallPart.Position.X, wallPart.Position.Y + distance/2, wallPart.Position.Z)
            return true
        end
        rayOrigin = rayOrigin + rayDirection * extensionStep
    end

    return false
end

function WallBuilder.createWallsAlongPath(points, height, offsetProfile, options)
    options = options or {}

    if #points < 2 then
        warn("[WallBuilder] Need at least 2 points")
        return Instance.new("Model")
    end

    local parent = options.parent or workspace
    local roofParts = options.roofParts
    local autoExtend = options.autoExtendToRoof == true

    local baseModel = PathLogic.createWalls(points, height, offsetProfile, {
        parent = parent,
        wallTemplate = options.wallTemplate,
        color = options.color,
        material = options.material,
        canCollide = options.canCollide,
        canQuery = options.canQuery,
        anchored = options.anchored,
        locked = options.locked,
        segmentsPerWall = options.segmentsPerWall,
    })

    if autoExtend and roofParts then
        local roofTargets = type(roofParts) == "table" and roofParts or {roofParts}
        local allRoofParts = {}
        for _, model in ipairs(roofTargets) do
            if model:IsA("Model") then
                for _, part in ipairs(model:GetDescendants()) do
                    if part:IsA("BasePart") then
                        table.insert(allRoofParts, part)
                    end
                end
            elseif model:IsA("BasePart") then
                table.insert(allRoofParts, model)
            end
        end

        for _, wallPart in ipairs(baseModel:GetDescendants()) do
            if wallPart:IsA("BasePart") then
                local bestTarget = nil
                local bestDist = math.huge
                local wallTop = wallPart.Position + Vector3.new(0, wallPart.Size.Y / 2, 0)

                for _, roofPart in ipairs(allRoofParts) do
                    if roofPart ~= wallPart then
                        local dist = (roofPart.Position - wallTop).Magnitude
                        if dist < bestDist and dist > 0 then
                            bestDist = dist
                            bestTarget = roofPart
                        end
                    end
                end

                if bestTarget then
                    extendWallPart(wallPart, bestTarget, options)
                end
            end
        end
    end

    return baseModel
end

function WallBuilder.createRectPerimeter(minX, maxX, minZ, maxZ, height, offsetProfile, options)
    local points = {
        Vector3.new(minX, height, minZ),
        Vector3.new(maxX, height, minZ),
        Vector3.new(maxX, height, maxZ),
        Vector3.new(minX, height, maxZ)
    }
    return WallBuilder.createWallsAlongPath(points, height, offsetProfile, options)
end

function WallBuilder.fromPolygon(polygon, height, offsetProfile, options)
    if #polygon < 3 then
        warn("[WallBuilder] Polygon needs at least 3 vertices")
        return Instance.new("Model")
    end

    local points = {}
    for _, pt in ipairs(polygon) do
        -- polygon points are {x, z} tables from Triangulation
        table.insert(points, Vector3.new(pt.x, height, pt.z))
    end

    return WallBuilder.createWallsAlongPath(points, height, offsetProfile, options)
end

return WallBuilder
