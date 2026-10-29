function widget:GetInfo()
	return {
		name    = "Compass Rose",
		desc    = "Shows a compass rose that stays oriented to map north. Drag with left mouse to move.",
		author  = "gweaver",
		date    = "2026-10-19",
		license = "GNU GPL v2",
		layer   = 0,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local SIZE        = 46      -- radius of rose in pixels (scaled by ui scale)
local MARGIN      = 12      -- gap from minimap
local FONT_SIZE   = 14

local colRoseDark  = {0.15, 0.15, 0.15, 0.85}
local colRoseLight = {0.85, 0.85, 0.85, 0.90}
local colNorth     = {0.90, 0.20, 0.20, 0.95}
local colPointer   = {1.00, 0.85, 0.20, 1.00}
local colBg        = {0.00, 0.00, 0.00, 0.35}
local colText      = "\255\255\255\255"
local colTextN     = "\255\255\080\080"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local posX, posY          -- center in GL coords (origin bottom-left)
local userPlaced = false
local locked     = false
local dragging   = false
local dragDX, dragDY = 0, 0
local vsx, vsy = Spring.GetViewGeometry()
local scale = 1

local glColor, glVertex, glBeginEnd = gl.Color, gl.Vertex, gl.BeginEnd
local glPushMatrix, glPopMatrix = gl.PushMatrix, gl.PopMatrix
local glTranslate, glRotate, glText = gl.Translate, gl.Rotate, gl.Text
local GL_TRIANGLES, GL_TRIANGLE_FAN = GL.TRIANGLES, GL.TRIANGLE_FAN
local GL_QUADS, GL_LINE_STRIP = GL.QUADS, GL.LINE_STRIP
local glLineWidth = gl.LineWidth
local colLock = {0.85, 0.85, 0.85, 1.00}
local sin, cos, atan2, rad, deg = math.sin, math.cos, math.atan2, math.rad, math.deg

--------------------------------------------------------------------------------
-- Positioning
--------------------------------------------------------------------------------
local function DefaultPosition()
	scale = (vsy / 1080) * (Spring.GetConfigFloat("ui_scale", 1) or 1)
	local r = SIZE * scale
	local mx, my, mw, mh = Spring.GetMiniMapGeometry()
	if mx and mw and mw > 0 then
		-- right of the minimap, vertically centered on its top section
		posX = mx + mw + MARGIN * scale + r
		posY = my + mh - r - MARGIN * scale
		if posY < r or posY > vsy - r then
			posY = vsy - r - MARGIN * scale   -- fallback: top of screen
		end
	else
		posX = vsx * 0.25
		posY = vsy - r - MARGIN * scale
	end
end

function widget:ViewResize(nx, ny)
	vsx, vsy = nx, ny
	scale = (vsy / 1080) * (Spring.GetConfigFloat("ui_scale", 1) or 1)
	if not userPlaced then DefaultPosition() end
end

function widget:Initialize()
	vsx, vsy = Spring.GetViewGeometry()
	if not userPlaced then DefaultPosition() end
end

--------------------------------------------------------------------------------
-- Heading: angle (deg, clockwise from north) the camera is facing.
-- Uses the camera's right vector, which stays horizontal even top-down.
--------------------------------------------------------------------------------
local function GetHeading()
	local v = Spring.GetCameraVectors()
	local r = v and v.right
	if not r then return 0 end
	return deg(atan2(r[3], r[1]))
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------
local function Tri(ax, ay, bx, by, cx, cy, col)
	glColor(col)
	glBeginEnd(GL_TRIANGLES, function()
		glVertex(ax, ay); glVertex(bx, by); glVertex(cx, cy)
	end)
end

local function DrawCircle(r, col)
	glColor(col)
	glBeginEnd(GL_TRIANGLE_FAN, function()
		glVertex(0, 0)
		for i = 0, 32 do
			local a = i / 32 * 2 * math.pi
			glVertex(cos(a) * r, sin(a) * r)
		end
	end)
end

-- One arm of the star: two halves for a shaded look
local function Arm(len, w, dark, light)
	Tri(0, 0, 0, len, -w, w, light)
	Tri(0, 0, w, w, 0, len, dark)
end

function widget:DrawScreen()
	if not posX then DefaultPosition() end
	local r = SIZE * scale
	local heading = GetHeading()

	glPushMatrix()
	glTranslate(posX, posY, 0)

	DrawCircle(r * 1.05, colBg)

	-- Rotating rose (north arm points to map north)
	glPushMatrix()
	glRotate(heading, 0, 0, 1)
	local len, w = r * 0.72, r * 0.16
	for i = 0, 3 do
		glPushMatrix()
		glRotate(-90 * i, 0, 0, 1)
		if i == 0 then
			Arm(len, w, {0.6, 0.1, 0.1, 0.95}, colNorth)
		else
			Arm(len, w, colRoseDark, colRoseLight)
		end
		glPopMatrix()
	end
	glPopMatrix()

	local pt = r * 1.05
	if locked then
		-- Small padlock at top
		local bw, bh = r * 0.11, r * 0.09          -- half-width, height of body
		local by = pt - r * 0.06                    -- body bottom
		glColor(colLock)
		glBeginEnd(GL_QUADS, function()
			glVertex(-bw, by); glVertex(bw, by)
			glVertex(bw, by + bh); glVertex(-bw, by + bh)
		end)
		local sr = bw * 0.65                        -- shackle radius
		glLineWidth(math.max(1.5, 2 * scale))
		glBeginEnd(GL_LINE_STRIP, function()
			glVertex(-sr, by + bh)
			for i = 0, 12 do
				local a = math.pi - i / 12 * math.pi
				glVertex(cos(a) * sr, by + bh + r * 0.03 + sin(a) * sr)
			end
			glVertex(sr, by + bh)
		end)
		glLineWidth(1)
	else
		-- Fixed pointer at top = direction the camera is looking
		Tri(0, pt - r * 0.18, -r * 0.09, pt + r * 0.02, r * 0.09, pt + r * 0.02, colPointer)
	end

	glPopMatrix()

	-- Upright labels placed around the rotated rose
	local fs = FONT_SIZE * scale
	local lr = r * 0.88
	local labels = { {"N", 0}, {"E", 90}, {"S", 180}, {"W", 270} }
	for _, l in ipairs(labels) do
		-- screen angle: north at 90° (up) rotated CCW by heading
		local a = rad(90 + heading - l[2])
		local tx = posX + cos(a) * lr
		local ty = posY + sin(a) * lr - fs * 0.35
		glText((l[1] == "N" and colTextN or colText) .. l[1], tx, ty, fs, "co")
	end
	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- Dragging
--------------------------------------------------------------------------------
local function Inside(x, y)
	local r = SIZE * scale * 1.1
	local dx, dy = x - posX, y - posY
	return dx * dx + dy * dy <= r * r
end

function widget:IsAbove(x, y) return posX and Inside(x, y) end
function widget:GetTooltip()
	return locked and "Compass Rose (locked - right-click to unlock)"
		or "Compass Rose (drag to move, right-click to lock)"
end

function widget:MousePress(x, y, button)
	if not Inside(x, y) then return false end
	if button == 3 then
		locked = not locked
		dragging = false
		return true
	end
	if button == 1 and not locked then
		dragging = true
		dragDX, dragDY = posX - x, posY - y
		return true
	end
	return false
end

function widget:MouseMove(x, y)
	if dragging then
		posX, posY = x + dragDX, y + dragDY
		userPlaced = true
	end
end

function widget:MouseRelease()
	dragging = false
	return false
end

--------------------------------------------------------------------------------
-- Persist position
--------------------------------------------------------------------------------
function widget:GetConfigData()
	local data = { locked = locked }
	if userPlaced and posX then
		data.x, data.y = posX / vsx, posY / vsy
	end
	return data
end

function widget:SetConfigData(data)
	if not data then return end
	locked = data.locked or false
	if data.x and data.y then
		local sx, sy = Spring.GetViewGeometry()
		posX, posY = data.x * sx, data.y * sy
		userPlaced = true
	end
end
