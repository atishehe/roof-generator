local CSGUtil = {}
local remote = game.ReplicatedStorage:WaitForChild("CSGRemote")

local function serializePart(part)
    return {
        partType     = part.ClassName,
        cframe       = part.CFrame,
        size         = part.Size,
        color        = part.Color,
        transparency = part.Transparency,
    }
end

local function serializeParts(parts)
    local data = {}
    for _, p in ipairs(parts) do
        table.insert(data, serializePart(p))
        p:Destroy()
    end
    return data
end
-- for polling workspace for instances with matching UID attributeeeee
local function findByUID(uid, timeout)
    local t = 0
    while t < (timeout or 10) do
        for _, v in ipairs(workspace:GetDescendants()) do
            if v:GetAttribute("csgUID") == uid then
                v:SetAttribute("csgUID", nil)
                return v
            end
        end
        task.wait(0.05)
        t = t + 0.05
    end
    warn("CSGUtil: timed out waiting for uid=" .. tostring(uid))
    return nil
end

function CSGUtil.subtract(mainPart, otherParts, properties)
    if not mainPart or not mainPart.Parent then
        warn("CSGUtil.subtract: mainPart nil")
        return nil
    end
    local serialized = serializeParts(otherParts)
    local uid = remote:InvokeServer("subtract", mainPart, serialized, properties)
    if not uid then return nil end
    return findByUID(uid, 10)
end

function CSGUtil.union(mainPart, otherParts, properties)
    if not mainPart or not mainPart.Parent then
        warn("CSGUtil.union: mainPart nil")
        return nil
    end
    local serialized = serializeParts(otherParts)
    return remote:InvokeServer("union", mainPart, serialized, properties)
end

function CSGUtil.unionAll(allParts, properties)
    if not allParts or #allParts < 2 then
        warn("CSGUtil.unionAll: need at least 2 parts")
        return nil
    end
    local serialized = serializeParts(allParts)
    local uid = remote:InvokeServer("unionAll", serialized, properties)
    if not uid then return nil end
    return findByUID(uid, 15)
end

return CSGUtil
