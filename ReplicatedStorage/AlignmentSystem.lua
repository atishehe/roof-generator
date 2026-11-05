local CSGUtil = require(game.ReplicatedStorage:WaitForChild('CSGUtil'))
local module = {}
local UIS = game:GetService("UserInputService")
local Players = game:GetService("Players")
local folderManager = require(script.Parent.folderManager)

local isBuilding = false
local isRemoving = false
local buildObject = nil
local realModel = nil
local rotateAmount = 0
local axisLock = script.Configuration.axisLock
local grid = script.Configuration.grid
local currentCategory = nil
local selectedForDelete = nil
local isLight = nil

local function getMouse()
	return require(script.Parent.pluginMouse).getMouse()
end

local function getMousePosition()
	local mouse = getMouse()
	if not mouse then return Vector3.new(0, axisLock.Value.Y, 0) end
	local hit = mouse.Hit
	if not hit then return Vector3.new(0, axisLock.Value.Y, 0) end
	local hitPosition = hit.Position
	local size = Vector3.new(1, 1, 1)
	if buildObject then
		if buildObject:IsA("Model") then
			local ext = buildObject:GetExtentsSize()
			size = ext.Magnitude > 0 and ext or size
		elseif buildObject:IsA("BasePart") then
			size = buildObject.Size
		end
	end
	local yoffset = 0
	if isLight then
		yoffset = 10 - size.Y
	end
	return Vector3.new(
		math.round(hitPosition.X / grid.Value.X) * grid.Value.X,
		axisLock.Value.Y + (size.Y / 2) + yoffset,
		math.round(hitPosition.Z / grid.Value.Z) * grid.Value.Z
	)
end

function module.rotate(amount, requiresBuilding)
	if isBuilding or require(script.Parent.decor).getBuilding() or not requiresBuilding then
		rotateAmount = amount
	end
end

function module.getRotate()
	return rotateAmount
end

function module.getBuilding()
	return isBuilding
end

function module.getBuild()
	return realModel
end

function module.previewBuild(object, categoryName, light)
	isLight = light and true or false
	if workspace:FindFirstChild("builds") then
		for _, v in pairs(workspace.builds:GetDescendants()) do
			if v:IsA("BasePart") then v.Locked = true end
		end
	end
	folderManager.clear()
	realModel = object
	if categoryName then currentCategory = categoryName end
	buildObject = object:Clone()
	if buildObject:IsA("BasePart") then buildObject.Locked = true end
	for _, v in pairs(buildObject:GetDescendants()) do
		if v:IsA("BasePart") then v.Locked = true end
	end
	folderManager.setCategoryFolder("cache", buildObject)
	for _, v in pairs(buildObject:GetDescendants()) do
		if v:IsA("BasePart") then
			v.Anchored = true
			v.CanCollide = false
			v.CanTouch = false
			v.CanQuery = false
		end
	end
	if buildObject:IsA("BasePart") then
		buildObject.Anchored = true
		buildObject.CanCollide = false
		buildObject.CanTouch = false
		buildObject.CanQuery = false
	end
	isBuilding = true
	task.spawn(function()
		while isBuilding do
			local ok, err = pcall(function()
				local mousePos = getMousePosition()
				buildObject:PivotTo(CFrame.new(mousePos) * CFrame.Angles(0, math.rad(rotateAmount), 0))
			end)
			if not ok then
			end
			task.wait()
		end
		if buildObject and buildObject.Parent then
			buildObject:Destroy()
			buildObject = nil
		end
	end)
end

function module.cancel()
	isBuilding = false
	isRemoving = false
	folderManager.clear()
	if workspace:FindFirstChild("builds") then
		for _, v in pairs(workspace.builds:GetDescendants()) do
			if v:IsA("ClickDetector") and v.Name == "removeClickDetector" then
				v:Destroy()
			end
		end
	end
end

local function addTrim(model, trim)
	if not workspace:FindFirstChild("builds") then return trim end
	local trimParts = {}
	local objCFrame = model:GetPivot()
	local objSize = model:GetExtentsSize()
	local trimCFrame = trim.CFrame
	local trimSize = trim.Size
	local intersectMinY = math.max(objCFrame.Position.Y - objSize.Y / 2, trimCFrame.Position.Y - trimSize.Y / 2)
	local intersectMaxY = math.min(objCFrame.Position.Y + objSize.Y / 2, trimCFrame.Position.Y + trimSize.Y / 2)
	local intersectSizeY = intersectMaxY - intersectMinY
	if intersectSizeY > 0 then
		local localPosition = model:GetPivot():PointToObjectSpace(Vector3.new(objCFrame.Position.X, intersectMinY + intersectSizeY / 2, objCFrame.Position.Z))
		local part = Instance.new("Part")
		part.Size = Vector3.new(objSize.X + 0.01, intersectSizeY, trimSize.Z)
		part.CFrame = model:GetPivot() * CFrame.new(localPosition)
		part.Anchored = true
		part.Color = trim.Color
		part.Transparency = 0.5
		part.Locked = true
		part.Name = "negatePart"
		folderManager.setCategoryFolder("cache", part)
		table.insert(trimParts, part)
	end
	if #trimParts == 0 then return trim end
	local oldObjects = {}
	local builds = workspace.builds
	if builds:FindFirstChild("windows") then
		for _, folder in pairs(builds.windows:GetChildren()) do
			for _, window in pairs(folder:GetChildren()) do
				if window:FindFirstChild("originalTrim") and window.originalTrim.Value == trim then
					table.insert(oldObjects, window.originalTrim)
				end
			end
		end
	end
	if builds:FindFirstChild("doors") then
		for _, folder in pairs(builds.doors:GetChildren()) do
			for _, door in pairs(folder:GetChildren()) do
				if door:FindFirstChild("originalTrim") and door.originalTrim.Value == trim then
					table.insert(oldObjects, door.originalTrim)
				end
			end
		end
	end
	local originalWall = trim:FindFirstChild("originalWall")
	local union = CSGUtil.union(trim, trimParts, {RenderFidelity="Precise", CollisionFidelity=Enum.CollisionFidelity.PreciseConvexDecomposition, UsePartColor=true, Anchored=true, Locked=true})
	if not union then return trim end
	union.RenderFidelity = Enum.RenderFidelity.Precise
	union.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
	union.UsePartColor = true
	union.Anchored = true
	union.CanCollide = true
	union.Name = trim.Name
	union.Parent = trim.Parent
	union.Locked = true
	if originalWall then originalWall.Parent = union end
	trim:Destroy()
	for _, v in pairs(trimParts) do v:Destroy() end
	local originalTrim = Instance.new("ObjectValue")
	originalTrim.Parent = model
	originalTrim.Name = "originalTrim"
	originalTrim.Value = union
	for _, v in pairs(oldObjects) do v.Value = union end
	return union
end

local function fillWall(model, wall)
	local part = Instance.new("Part")
	part.Parent = workspace
	local modelSize = model:GetExtentsSize()
	local modelCFrame = model:GetPivot()
	local wallSize = wall.Size
	local wallCFrame = wall.CFrame
	local modelLocalCFrame = wallCFrame:ToObjectSpace(modelCFrame)
	local halfWallSizeX = wallSize.X / 2
	local halfWallSizeY = wallSize.Y / 2
	local modelMinX = modelLocalCFrame.Position.X - modelSize.X / 2
	local modelMaxX = modelLocalCFrame.Position.X + modelSize.X / 2
	local modelMinY = modelLocalCFrame.Position.Y - modelSize.Y / 2
	local modelMaxY = modelLocalCFrame.Position.Y + modelSize.Y / 2
	local clampedMinX = math.max(modelMinX, -halfWallSizeX)
	local clampedMaxX = math.min(modelMaxX, halfWallSizeX)
	local clampedMinY = math.max(modelMinY, -halfWallSizeY)
	local clampedMaxY = math.min(modelMaxY, halfWallSizeY)
	part.Size = Vector3.new(clampedMaxX - clampedMinX, clampedMaxY - clampedMinY, wallSize.Z)
	part.CFrame = modelCFrame
	part.Anchored = true
	return part
end

function module.remove(model)
	local doors = folderManager.getCategory("doors")
	local windows = folderManager.getCategory("windows")
	local trims = folderManager.getCategory("trims")
	if workspace:FindFirstChild("builds") then
		for _, v in pairs(workspace.builds:GetDescendants()) do
			if v:IsA("BasePart") then v.Locked = true end
		end
	end
	if model.Parent and (model.Parent.Parent.Name == "doors" or model.Parent.Parent.Name == "windows") then
		local originalWallVal = model:FindFirstChild("originalWall")
		if not originalWallVal then model:Destroy() module.cancel() module.previewRemove() return end
		local originalWall = originalWallVal.Value
		if not originalWall or not originalWall.Parent then model:Destroy() module.cancel() module.previewRemove() return end
		local part = fillWall(model, originalWall)
		local allValues = {}
		local function collectWallRefs(cat)
			if cat then
				for _, folder in pairs(cat:GetChildren()) do
					for _, object in pairs(folder:GetChildren()) do
						if object:FindFirstChild("originalWall") and object.originalWall.Value == originalWall and object ~= model then
							table.insert(allValues, object)
						end
					end
				end
			end
		end
		collectWallRefs(doors)
		collectWallRefs(windows)
		collectWallRefs(trims)
		local unionResult = CSGUtil.union(originalWall, {part}, {RenderFidelity="Precise", CollisionFidelity=Enum.CollisionFidelity.PreciseConvexDecomposition, UsePartColor=true, Anchored=true, Locked=true})
		if not unionResult then part:Destroy() model:Destroy() module.cancel() module.previewRemove() return end
		unionResult.RenderFidelity = Enum.RenderFidelity.Precise
		unionResult.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
		unionResult.CFrame = originalWall.CFrame
		unionResult.Parent = originalWall.Parent
		unionResult.Anchored = true
		unionResult.Locked = true
		unionResult.Name = "wall"
		originalWall:Destroy()
		part:Destroy()
		for _, v in pairs(allValues) do
			if v:FindFirstChild("originalWall") then
				v.originalWall.Value = unionResult
			end
		end
	elseif model.Parent and model.Parent.Name == "walls" then
		local allCats = {doors, windows, trims}
		for _, cat in ipairs(allCats) do
			if cat then
				for _, folder in pairs(cat:GetChildren()) do
					for _, object in pairs(folder:GetChildren()) do
						if object:FindFirstChild("originalWall") and object.originalWall.Value == model then
							object:Destroy()
						end
					end
				end
			end
		end
	end
	model:Destroy()
	module.cancel()
	module.previewRemove()
end

local function createSelectionBox(item)
	local function makeBox(v)
		if v:IsA("BasePart") then
			local sel = Instance.new("SelectionBox")
			sel.Parent = v
			sel.Adornee = v
			sel.Color3 = Color3.new(1, 0, 0)
			sel.LineThickness = 0.01
			sel.SurfaceColor3 = Color3.new(1, 0, 0)
			sel.SurfaceTransparency = 0.9
		end
	end
	for _, v in pairs(item:GetDescendants()) do makeBox(v) end
	makeBox(item)
end

local function clearSelectionBox()
	if workspace:FindFirstChild("builds") then
		for _, v in pairs(workspace.builds:GetDescendants()) do
			if v:IsA("SelectionBox") then v:Destroy() end
		end
	end
end

function module.previewRemove()
	local littleButtonsIcon = script.Parent.littleButtons.ImageButton
	isRemoving = true
	folderManager.clear()
	littleButtonsIcon.ImageColor3 = Color3.new(0.952941, 0.0392157, 0.329412)
	while isRemoving and workspace:FindFirstChild("builds") do
		local floorFolder = workspace.builds:FindFirstChild("Floor " .. (script:GetAttribute("currentFloor") or 1))
		if not floorFolder then task.wait(0.1) continue end
		local mouse = getMouse()
		if not mouse then task.wait(0.1) continue end
		local hit = mouse.Target
		if hit and hit:IsDescendantOf(floorFolder) then
			local items = {}
			for _, folder in pairs(floorFolder:GetChildren()) do
				for _, model in pairs(folder:GetChildren()) do
					if model:IsA("Folder") then
						for _, object in pairs(model:GetChildren()) do table.insert(items, object) end
					else
						table.insert(items, model)
					end
				end
			end
			local found = false
			for _, item in pairs(items) do
				if (hit == item or hit:IsDescendantOf(item)) and item ~= selectedForDelete then
					if selectedForDelete then clearSelectionBox() end
					createSelectionBox(item)
					selectedForDelete = item
					found = true
					break
				end
			end
			if not found and not (selectedForDelete and (hit == selectedForDelete or hit:IsDescendantOf(selectedForDelete))) then
				if selectedForDelete then clearSelectionBox() selectedForDelete = nil end
			end
		elseif selectedForDelete then
			clearSelectionBox()
			selectedForDelete = nil
		end
		task.wait(0.01)
	end
	isRemoving = false
	littleButtonsIcon.ImageColor3 = Color3.new(0.203922, 0.203922, 0.203922)
	clearSelectionBox()
end

UIS.InputBegan:Connect(function(input, gpe)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and not gpe then
		if isBuilding and buildObject then
			local clone = realModel:Clone()
			clone.Name = realModel.Name
			clone:PivotTo(buildObject:GetPivot())
			-- Make placed object collidable
			for _, v in pairs(clone:GetDescendants()) do
				if v:IsA("BasePart") then
					v.Anchored = true
					v.CanCollide = true
					v.CanTouch = true
					v.CanQuery = true
				end
			end
			if clone:IsA("BasePart") then
				clone.Anchored = true
				clone.CanCollide = true
				clone.CanTouch = true
				clone.CanQuery = true
			end
			folderManager.setCategoryFolder(currentCategory, clone)
		elseif isRemoving and selectedForDelete then
			module.remove(selectedForDelete)
		end
	end
end)

return module
