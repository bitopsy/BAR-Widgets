function widget:GetInfo()
	return {
		name    = "Zombie Radar",
		desc    = "Estimates zombie biomass (wreck metal) around the map as clusters. Draggable HUD, minimap + world markers.",
		author  = "goddot",
		date    = "2026-10-29",
		license = "GNU GPL, v2 or later",
		layer   = 5,
		enabled = false,
	}
end

--------------------------------------------------------------------------------
-- Zombie Radar  (gui_zombie_radar)
--
--  Discord: https://discord.com/channels/549281623154229250/1565483540076822599
--  GitHub:  https://github.com/bitopsy/BAR-Widgets/tree/main/Widgets/community/gui_zombie_radar
--
--  * Scans all visible features, keeps the ones that can be resurrected (wrecks)
--    = future zombies, and groups them into spatial clusters.
--  * HUD panel: biomass (metal) + estimated zombie count, radar thumbnail with
--    sweep, ranked cluster list. Drag anywhere on the panel to move it.
--  * Click a list row / radar blip to jump the camera there.
--  * Mouse wheel over the panel = resize.  [-]/[+] button = collapse.
--  * Footer pill toggles WRECKS ONLY <-> ALL METAL (includes map rocks/heaps).
--  * World: pulsing rings, light beams and labels over each cluster.
--  * Minimap: cluster blobs.
--
--  Note: features are only known inside your LOS/radar unless you are spectating
--  with full view, so numbers are an *estimate*.
--------------------------------------------------------------------------------

---------------------------------- SETTINGS ------------------------------------

local CELL               = 352     -- clustering grid size (elmos); clusters = touching cells
local MIN_FEATURE_METAL  = 1       -- ignore features with less metal than this
local MAX_CLUSTERS       = 40
local MAX_ROWS           = 6       -- rows in the HUD list
local MAX_WORLD_LABELS   = 12
local SCAN_INTERVAL      = 0.8     -- seconds between rescans
local MINIMAP_UNIT_SPACE = true    -- if minimap blobs are misplaced, set this to false

---------------------------------- LOCALS --------------------------------------

local floor, max, min, sqrt, sin, cos, pi, atan2 =
	math.floor, math.max, math.min, math.sqrt, math.sin, math.cos, math.pi, math.atan2
local format = string.format

local spGetAllFeatures      = Spring.GetAllFeatures
local spGetFeaturePosition  = Spring.GetFeaturePosition
local spGetFeatureResources = Spring.GetFeatureResources
local spGetFeatureResurrect = Spring.GetFeatureResurrect
local spGetGroundHeight     = Spring.GetGroundHeight
local spGetViewGeometry     = Spring.GetViewGeometry
local spGetMouseState       = Spring.GetMouseState
local spSetCameraTarget     = Spring.SetCameraTarget
local spIsGUIHidden         = Spring.IsGUIHidden
local spTraceScreenRay      = Spring.TraceScreenRay

local glColor, glRect, glText, glVertex, glBeginEnd, glLineWidth, glBlend =
	gl.Color, gl.Rect, gl.Text, gl.Vertex, gl.BeginEnd, gl.LineWidth, gl.Blending

local mapX, mapZ = Game.mapSizeX, Game.mapSizeZ
local vsx, vsy = spGetViewGeometry()

-- persistent UI state
local posX, posY          -- top-left corner of the panel (screen px, origin bottom-left)
local scale     = 1.0
local collapsed = false
local includeAll = false  -- false = wrecks only (resurrectable), true = every feature with metal

-- data
local clusters = {}
local totalMetal, totalZ, totalFeatures = 0, 0, 0
local dispMetal, dispZ = 0, 0
local lastScan, lastDraw = -100, os.clock()

-- interaction
local dragging, dragOffX, dragOffY = false, 0, 0
local hoverIdx = nil
local layout = nil

---------------------------------- HELPERS -------------------------------------

local function clamp(v, a, b) return v < a and a or (v > b and b or v) end

local function InRect(x, y, x1, y1, x2, y2)
	return x >= x1 and x <= x2 and y >= y1 and y <= y2
end

local function Fmt(n)
	if n >= 10000 then return format("%.1fk", n / 1000)
	elseif n >= 1000 then return format("%.2fk", n / 1000)
	else return format("%d", floor(n + 0.5)) end
end

-- small -> toxic green, medium -> yellow, big -> orange, huge -> blood red
local function Severity(m)
	if m < 300 then
		return 0.45, 1.0, 0.22
	elseif m < 900 then
		local t = (m - 300) / 600
		return 0.45 + 0.5 * t, 1.0 - 0.1 * t, 0.22
	elseif m < 2200 then
		local t = (m - 900) / 1300
		return 0.95 + 0.05 * t, 0.9 - 0.4 * t, 0.22 - 0.1 * t
	else
		local t = min(1, (m - 2200) / 3000)
		return 1.0, 0.5 - 0.35 * t, 0.1 + 0.05 * t
	end
end

local dirNames = { "E", "NE", "N", "NW", "W", "SW", "S", "SE" }
local function Sector(x, z)
	local dx, dz = x - mapX * 0.5, z - mapZ * 0.5
	local lim = min(mapX, mapZ) * 0.12
	if dx * dx + dz * dz < lim * lim then return "CTR" end
	local ang = atan2(-dz, dx)
	if ang < 0 then ang = ang + 2 * pi end
	return dirNames[floor(ang / (pi / 4) + 0.5) % 8 + 1]
end

-- text with vertical centre at yc
local function Txt(str, x, yc, size, opt)
	glText(str, x, yc - size * 0.33, size, opt)
end

local function GoTo(x, z)
	spSetCameraTarget(x, spGetGroundHeight(x, z) or 0, z, 0.6)
end

---------------------------------- GL SHAPES -----------------------------------
-- (shared upvalues so we don't allocate closures every frame)

local RR_SEGS = 5
local rrx1, rry1, rrx2, rry2, rrr, rrFan = 0, 0, 0, 0, 0, true
local cornerAng = { 0, pi * 0.5, pi, pi * 1.5 }
local function rrVerts()
	local r = rrr
	if rrFan then glVertex((rrx1 + rrx2) * 0.5, (rry1 + rry2) * 0.5) end
	for c = 1, 4 do
		local cx = (c == 1 or c == 4) and (rrx2 - r) or (rrx1 + r)
		local cy = (c <= 2) and (rry2 - r) or (rry1 + r)
		local a0 = cornerAng[c]
		for i = 0, RR_SEGS do
			local a = a0 + i * (pi * 0.5 / RR_SEGS)
			glVertex(cx + cos(a) * r, cy + sin(a) * r)
		end
	end
	if rrFan then glVertex(rrx2, rry2 - r) end
end
local function RoundRect(x1, y1, x2, y2, r)
	rrx1, rry1, rrx2, rry2, rrr, rrFan = x1, y1, x2, y2, r, true
	glBeginEnd(GL.TRIANGLE_FAN, rrVerts)
end
local function RoundRectLine(x1, y1, x2, y2, r)
	rrx1, rry1, rrx2, rry2, rrr, rrFan = x1, y1, x2, y2, r, false
	glBeginEnd(GL.LINE_LOOP, rrVerts)
end

local dcx, dcy, dcr, dsegs, dasp = 0, 0, 1, 20, 1
local function discVerts()
	glVertex(dcx, dcy)
	for i = 0, dsegs do
		local a = i / dsegs * 2 * pi
		glVertex(dcx + cos(a) * dcr, dcy + sin(a) * dcr * dasp)
	end
end
local function ringVerts()
	for i = 0, dsegs - 1 do
		local a = i / dsegs * 2 * pi
		glVertex(dcx + cos(a) * dcr, dcy + sin(a) * dcr * dasp)
	end
end
local function Disc(x, y, r, segs, asp)
	dcx, dcy, dcr, dsegs, dasp = x, y, r, segs or 20, asp or 1
	glBeginEnd(GL.TRIANGLE_FAN, discVerts)
end
local function Ring(x, y, r, segs, asp)
	dcx, dcy, dcr, dsegs, dasp = x, y, r, segs or 24, asp or 1
	glBeginEnd(GL.LINE_LOOP, ringVerts)
end

local function Skull(cx, cy, s, t)
	local flick = 0.75 + 0.25 * sin(t * 3)
	glColor(0.55, 1.0, 0.3, 0.25 * flick)
	Disc(cx, cy, 15 * s, 20)
	glColor(0.72, 1.0, 0.5, 1)
	Disc(cx, cy + 2 * s, 9 * s, 20)
	glRect(cx - 5.5 * s, cy - 9 * s, cx + 5.5 * s, cy - 3 * s)
	glColor(0.02, 0.05, 0.02, 1)
	Disc(cx - 3.6 * s, cy + 3 * s, 2.7 * s, 10)
	Disc(cx + 3.6 * s, cy + 3 * s, 2.7 * s, 10)
	glRect(cx - 0.7 * s, cy - 1.5 * s, cx + 0.7 * s, cy + 0.8 * s)
	glRect(cx - 2.6 * s, cy - 9 * s, cx - 1.8 * s, cy - 5.5 * s)
	glRect(cx - 0.4 * s, cy - 9 * s, cx + 0.4 * s, cy - 5.5 * s)
	glRect(cx + 1.8 * s, cy - 9 * s, cx + 2.6 * s, cy - 5.5 * s)
end

---------------------------------- SCANNING ------------------------------------

local function Scan()
	local feats = spGetAllFeatures()
	local cells, keys = {}, {}
	local tMetal, tCount = 0, 0

	for i = 1, #feats do
		local fid = feats[i]
		local m = spGetFeatureResources(fid)
		if m and m >= MIN_FEATURE_METAL then
			local res = spGetFeatureResurrect(fid)
			if includeAll or (res and res ~= "") then
				local x, _, z = spGetFeaturePosition(fid)
				if x then
					local cx, cz = floor(x / CELL), floor(z / CELL)
					local key = cz * 4096 + cx
					local c = cells[key]
					if not c then
						c = { cx = cx, cz = cz, m = 0, n = 0, sx = 0, sz = 0, w = 0 }
						cells[key] = c
						keys[#keys + 1] = key
					end
					local w = m + 1
					c.m, c.n = c.m + m, c.n + 1
					c.sx, c.sz, c.w = c.sx + x * w, c.sz + z * w, c.w + w
					tMetal, tCount = tMetal + m, tCount + 1
				end
			end
		end
	end

	-- flood-fill touching cells into clusters
	local out = {}
	for i = 1, #keys do
		local c0 = cells[keys[i]]
		if not c0.seen then
			c0.seen = true
			local stack, members = { c0 }, {}
			local cl = { m = 0, n = 0, sx = 0, sz = 0, w = 0 }
			while #stack > 0 do
				local c = stack[#stack]
				stack[#stack] = nil
				members[#members + 1] = c
				cl.m, cl.n = cl.m + c.m, cl.n + c.n
				cl.sx, cl.sz, cl.w = cl.sx + c.sx, cl.sz + c.sz, cl.w + c.w
				for dz = -1, 1 do
					for dx = -1, 1 do
						if dx ~= 0 or dz ~= 0 then
							local nc = cells[(c.cz + dz) * 4096 + (c.cx + dx)]
							if nc and not nc.seen then
								nc.seen = true
								stack[#stack + 1] = nc
							end
						end
					end
				end
			end
			cl.x, cl.z = cl.sx / cl.w, cl.sz / cl.w
			local rad = 0
			for j = 1, #members do
				local c = members[j]
				local ddx, ddz = c.sx / c.w - cl.x, c.sz / c.w - cl.z
				rad = max(rad, sqrt(ddx * ddx + ddz * ddz))
			end
			cl.radius = max(130, rad + CELL * 0.5)
			cl.y = spGetGroundHeight(cl.x, cl.z) or 0
			cl.sector = Sector(cl.x, cl.z)
			out[#out + 1] = cl
		end
	end

	table.sort(out, function(a, b) return a.m > b.m end)
	for i = #out, MAX_CLUSTERS + 1, -1 do out[i] = nil end

	clusters = out
	totalMetal, totalZ, totalFeatures = tMetal, tCount, #feats
end

---------------------------------- LAYOUT --------------------------------------

local function ComputeLayout()
	local s = max(0.5, scale * vsy / 1080)
	local w = 290 * s
	local pad = 12 * s
	local hdr = 40 * s
	local nrows = max(1, min(MAX_ROWS, #clusters))
	local rowH, rowGap = 21 * s, 3 * s
	local statsH = 60 * s
	local radW = w - 2 * pad
	local radH = clamp(radW * mapZ / mapX, 70 * s, 150 * s)
	local listLblH = 20 * s
	local footH = 30 * s

	local h = hdr
	if not collapsed then
		h = hdr + statsH + radH + 8 * s + listLblH + nrows * (rowH + rowGap) + footH
	end

	posX = clamp(posX, 0, max(0, vsx - w))
	posY = clamp(posY, h, vsy)

	local L = { s = s, w = w, h = h, pad = pad }
	L.x1, L.x2, L.y2, L.y1 = posX, posX + w, posY, posY - h
	L.hdrB = L.y2 - hdr
	local bs = 20 * s
	L.btnC = { x1 = L.x2 - pad - bs, x2 = L.x2 - pad, y1 = L.y2 - hdr * 0.5 - bs * 0.5, y2 = L.y2 - hdr * 0.5 + bs * 0.5 }

	if not collapsed then
		local y = L.hdrB
		L.statsT, L.statsB = y, y - statsH
		y = L.statsB
		L.radar = { x1 = L.x1 + pad, x2 = L.x2 - pad, y2 = y, y1 = y - radH }
		y = L.radar.y1 - 8 * s
		L.listLblY = y - listLblH * 0.5
		y = y - listLblH
		L.rows = {}
		for i = 1, nrows do
			L.rows[i] = { x1 = L.x1 + pad * 0.6, x2 = L.x2 - pad * 0.6, y2 = y, y1 = y - rowH }
			y = y - rowH - rowGap
		end
		L.nrows = nrows
		local bw, bh = 108 * s, 18 * s
		local fy = L.y1 + footH * 0.5
		L.btnM = { x1 = L.x1 + pad, x2 = L.x1 + pad + bw, y1 = fy - bh * 0.5, y2 = fy + bh * 0.5 }
		L.footY = fy
	end
	return L
end

local function RadarXY(L, wx, wz)
	local r = L.radar
	return r.x1 + wx / mapX * (r.x2 - r.x1), r.y2 - wz / mapZ * (r.y2 - r.y1)
end

local function DetectHover(L, mx, my)
	hoverIdx = nil
	if collapsed or not InRect(mx, my, L.x1, L.y1, L.x2, L.y2) then return end
	for i = 1, L.nrows do
		local r = L.rows[i]
		if clusters[i] and InRect(mx, my, r.x1, r.y1, r.x2, r.y2) then
			hoverIdx = i
			return
		end
	end
	local r = L.radar
	if InRect(mx, my, r.x1, r.y1, r.x2, r.y2) then
		local best, bd = nil, (12 * L.s) ^ 2
		for i = 1, #clusters do
			local bx, by = RadarXY(L, clusters[i].x, clusters[i].z)
			local d = (bx - mx) ^ 2 + (by - my) ^ 2
			if d < bd then best, bd = i, d end
		end
		hoverIdx = best
	end
end

---------------------------------- DRAWING: HUD --------------------------------

local dripFrac = { 0.10, 0.27, 0.41, 0.58, 0.72, 0.88 }

function widget:DrawScreen()
	if spIsGUIHidden() then return end

	local now = os.clock()
	local dt = min(0.1, now - lastDraw)
	lastDraw = now
	local k = min(1, dt * 5)
	dispMetal = dispMetal + (totalMetal - dispMetal) * k
	dispZ = dispZ + (totalZ - dispZ) * k

	local L = ComputeLayout()
	layout = L
	local s = L.s
	local x1, y1, x2, y2 = L.x1, L.y1, L.x2, L.y2
	local mx, my = spGetMouseState()
	DetectHover(L, mx, my)

	gl.Texture(false)
	glBlend(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

	-- outer glow + body
	glColor(0.3, 1.0, 0.15, 0.06)
	RoundRect(x1 - 5 * s, y1 - 5 * s, x2 + 5 * s, y2 + 5 * s, 15 * s)
	glColor(0.03, 0.05, 0.03, 0.90)
	RoundRect(x1, y1, x2, y2, 10 * s)

	-- header
	glColor(0.07, 0.13, 0.06, 0.98)
	RoundRect(x1, L.hdrB, x2, y2, 10 * s)
	if not collapsed then glRect(x1, L.hdrB, x2, L.hdrB + 10 * s) end
	glColor(0.4, 1.0, 0.2, 0.5)
	glRect(x1 + 8 * s, L.hdrB, x2 - 8 * s, L.hdrB + 1 * s)

	Skull(x1 + 24 * s, y2 - 20 * s, s, now)

	glColor(0.82, 1.0, 0.65, 1)
	Txt("ZOMBIE METAL RADAR", x1 + 46 * s, y2 - 14 * s, 14.5 * s, "o")
	glColor(0.45, 0.65, 0.4, 1)
	if collapsed then
		Txt(format("~%d Z  |  %sM", floor(dispZ + 0.5), Fmt(dispMetal)), x1 + 46 * s, y2 - 29 * s, 11 * s, "o")
	else
		Txt("biomass estimate", x1 + 46 * s, y2 - 29 * s, 11 * s, "o")
	end

	-- collapse button
	local bc = L.btnC
	local hovC = InRect(mx, my, bc.x1, bc.y1, bc.x2, bc.y2)
	glColor(0.35, 1.0, 0.2, hovC and 0.35 or 0.15)
	RoundRect(bc.x1, bc.y1, bc.x2, bc.y2, 4 * s)
	glColor(0.8, 1, 0.7, 1)
	Txt(collapsed and "+" or "-", (bc.x1 + bc.x2) * 0.5, (bc.y1 + bc.y2) * 0.5, 16 * s, "co")

	-- alert LED
	local led = (#clusters > 0) and (0.55 + 0.45 * sin(now * 4)) or 0.25
	if #clusters > 0 then glColor(1, 0.2, 0.15, led) else glColor(0.3, 1, 0.3, led) end
	Disc(bc.x1 - 10 * s, (bc.y1 + bc.y2) * 0.5, 3.5 * s, 12)

	if not collapsed then
		local pad = L.pad

		-- stats
		local colW = (L.w - 2 * pad) * 0.5
		glColor(0.45, 0.65, 0.4, 1)
		Txt("BIOMASS (METAL)", x1 + pad, L.statsT - 13 * s, 9.5 * s, "o")
		Txt("EST. ZOMBIES", x1 + pad + colW, L.statsT - 13 * s, 9.5 * s, "o")
		glColor(0.55, 1.0, 0.3, 1)
		Txt(Fmt(dispMetal), x1 + pad, L.statsT - 33 * s, 24 * s, "o")
		local zr = clamp(dispZ / 60, 0, 1)
		glColor(0.85 + 0.15 * zr, 0.95 - 0.6 * zr, 0.6 - 0.4 * zr, 1)
		Txt("~" .. floor(dispZ + 0.5), x1 + pad + colW, L.statsT - 33 * s, 24 * s, "o")
		glColor(0.45, 0.62, 0.42, 1)
		local sub
		if #clusters > 0 then
			sub = format("%d clusters  |  hotspot %s  %sM", #clusters, clusters[1].sector, Fmt(clusters[1].m))
		else
			sub = includeAll and "no metal features in sight" or "no wrecks in sight"
		end
		Txt(sub, x1 + pad, L.statsB + 8 * s, 10 * s, "o")

		-- radar thumbnail
		local r = L.radar
		local rw, rh = r.x2 - r.x1, r.y2 - r.y1
		glColor(0.01, 0.03, 0.01, 0.95)
		RoundRect(r.x1, r.y1, r.x2, r.y2, 5 * s)
		glLineWidth(1)
		glColor(0.3, 1.0, 0.2, 0.07)
		for i = 1, 3 do
			glRect(r.x1, r.y1 + rh * i / 4, r.x2, r.y1 + rh * i / 4 + 1)
			glRect(r.x1 + rw * i / 4, r.y1, r.x1 + rw * i / 4 + 1, r.y2)
		end
		for y = r.y1 + 2 * s, r.y2, 3 * s do
			glColor(0, 0, 0, 0.18)
			glRect(r.x1, y, r.x2, y + 1)
		end

		-- sweep
		local sweep = (now * 0.22) % 1
		local scanX = r.x1 + sweep * rw
		local band = min(rw * 0.2, scanX - r.x1)
		if band > 1 then
			glBeginEnd(GL.QUADS, function()
				glColor(0.4, 1, 0.2, 0.0); glVertex(scanX - band, r.y1)
				glColor(0.4, 1, 0.2, 0.22); glVertex(scanX, r.y1)
				glColor(0.4, 1, 0.2, 0.22); glVertex(scanX, r.y2)
				glColor(0.4, 1, 0.2, 0.0); glVertex(scanX - band, r.y2)
			end)
		end
		glColor(0.6, 1, 0.4, 0.6)
		glRect(scanX, r.y1, scanX + 1.5, r.y2)

		-- blips
		local maxM = clusters[1] and clusters[1].m or 1
		for i = #clusters, 1, -1 do
			local c = clusters[i]
			local bx, by = RadarXY(L, c.x, c.z)
			local f = (bx - r.x1) / rw
			local d = (sweep - f) % 1
			local glow = (1 - d) ^ 4
			local br = (2.5 + sqrt(c.m / maxM) * 7) * s
			local cr, cg, cb = Severity(c.m)
			glColor(cr, cg, cb, 0.18 + 0.25 * glow)
			Disc(bx, by, br * (1.4 + glow * 0.9), 16)
			glColor(cr, cg, cb, 0.65 + 0.35 * glow)
			Disc(bx, by, br, 14)
			if i == hoverIdx then
				glLineWidth(2)
				glColor(1, 1, 1, 0.95)
				Ring(bx, by, br + 4 * s, 20)
				glLineWidth(1)
			end
		end

		-- camera focus marker
		local _, cpos = spTraceScreenRay(vsx * 0.5, vsy * 0.5, true)
		if type(cpos) == "table" and cpos[1] then
			local cx, cy = RadarXY(L, clamp(cpos[1], 0, mapX), clamp(cpos[3], 0, mapZ))
			glColor(0.5, 0.9, 1, 0.9)
			glRect(cx - 4 * s, cy - 0.5, cx + 4 * s, cy + 0.5)
			glRect(cx - 0.5, cy - 4 * s, cx + 0.5, cy + 4 * s)
		end

		glColor(0.35, 1.0, 0.2, 0.35)
		RoundRectLine(r.x1, r.y1, r.x2, r.y2, 5 * s)
		glColor(0.4, 0.6, 0.38, 0.8)
		Txt("SCAN", r.x1 + 6 * s, r.y2 - 8 * s, 9 * s, "o")

		-- list
		glColor(0.45, 0.65, 0.4, 1)
		Txt("TOP INFECTIONS", x1 + pad, L.listLblY, 10 * s, "o")
		glColor(0.35, 1.0, 0.2, 0.2)
		glRect(x1 + pad + 98 * s, L.listLblY, x2 - pad, L.listLblY + 1)

		if #clusters == 0 then
			local r1 = L.rows[1]
			glColor(0.4, 0.55, 0.38, 1)
			Txt("the dead lie quiet...", (r1.x1 + r1.x2) * 0.5, (r1.y1 + r1.y2) * 0.5, 12 * s, "co")
		else
			for i = 1, L.nrows do
				local c, rr = clusters[i], L.rows[i]
				if c then
					local cr, cg, cb = Severity(c.m)
					local cy = (rr.y1 + rr.y2) * 0.5
					glColor(1, 1, 1, i == hoverIdx and 0.10 or 0.04)
					RoundRect(rr.x1, rr.y1, rr.x2, rr.y2, 4 * s)
					local frac = c.m / maxM
					glColor(cr, cg, cb, i == hoverIdx and 0.45 or 0.28)
					RoundRect(rr.x1, rr.y1, rr.x1 + max(8 * s, (rr.x2 - rr.x1) * frac), rr.y2, 4 * s)
					glColor(0.8, 0.95, 0.75, 1)
					Txt("#" .. i, rr.x1 + 6 * s, cy, 11.5 * s, "o")
					Txt(c.sector, rr.x1 + 32 * s, cy, 11.5 * s, "o")
					glColor(0.75, 0.85, 0.65, 1)
					Txt(c.n .. " Z", rr.x1 + 82 * s, cy, 11.5 * s, "o")
					glColor(cr, cg, cb, 1)
					Txt(Fmt(c.m) .. " M", rr.x2 - 6 * s, cy, 12.5 * s, "ro")
				end
			end
		end

		-- footer: mode pill + hint
		local bm = L.btnM
		local hovM = InRect(mx, my, bm.x1, bm.y1, bm.x2, bm.y2)
		if includeAll then glColor(0.7, 0.3, 1.0, hovM and 0.5 or 0.32) else glColor(0.35, 1.0, 0.2, hovM and 0.38 or 0.2) end
		RoundRect(bm.x1, bm.y1, bm.x2, bm.y2, 9 * s)
		glColor(0.9, 1, 0.85, 1)
		Txt(includeAll and "ALL METAL" or "WRECKS ONLY", (bm.x1 + bm.x2) * 0.5, L.footY, 10 * s, "co")
		glColor(0.38, 0.5, 0.36, 1)
		Txt("drag | wheel = size", x2 - pad, L.footY, 9 * s, "ro")
	end

	-- border
	glLineWidth(1.5)
	glColor(0.35, 1.0, 0.2, 0.40)
	RoundRectLine(x1, y1, x2, y2, 10 * s)

	-- slime drips along the bottom edge
	for i = 1, #dripFrac do
		local dx = x1 + L.w * dripFrac[i]
		local len = (4 + 12 * (0.5 + 0.5 * sin(now * (0.6 + i * 0.13) + i * 2.1))) * s
		local dw = (2.2 + (i % 3) * 0.8) * s
		glColor(0.4, 1.0, 0.2, 0.85)
		glRect(dx - dw * 0.5, y1 - len, dx + dw * 0.5, y1 + 2 * s)
		Disc(dx, y1 - len, dw * 0.95, 10)
	end

	glLineWidth(1)
	glBlend(false)
	glColor(1, 1, 1, 1)
end

---------------------------------- DRAWING: WORLD ------------------------------

function widget:DrawWorldPreUnit()
	if #clusters == 0 or spIsGUIHidden() then return end
	local t = os.clock()
	gl.DepthTest(false)
	glBlend(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	for i = 1, #clusters do
		local c = clusters[i]
		local r, g, b = Severity(c.m)
		local hov = (i == hoverIdx)
		local pulse = (t * 0.55 + i * 0.173) % 1

		glLineWidth(1)
		for k = 1, 4 do
			glColor(r, g, b, (hov and 0.18 or 0.09) * (1.25 - k * 0.2))
			gl.DrawGroundCircle(c.x, c.y, c.z, c.radius * k / 4, 40)
		end
		glLineWidth(hov and 3.5 or 2)
		glColor(r, g, b, hov and 1 or 0.7)
		gl.DrawGroundCircle(c.x, c.y, c.z, c.radius, 48)
		glLineWidth(1.5)
		glColor(r, g, b, 0.55 * (1 - pulse))
		gl.DrawGroundCircle(c.x, c.y, c.z, c.radius * (0.35 + 0.85 * pulse), 48)
	end
	glLineWidth(1)
	glBlend(false)
	glColor(1, 1, 1, 1)
end

function widget:DrawWorld()
	if #clusters == 0 or spIsGUIHidden() then return end
	glBlend(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	gl.DepthTest(true)
	glLineWidth(2)
	for i = 1, #clusters do
		local c = clusters[i]
		local r, g, b = Severity(c.m)
		local bh = 140 + clamp(c.m / 8, 0, 420)
		glBeginEnd(GL.LINES, function()
			glColor(r, g, b, 0.85); glVertex(c.x, c.y, c.z)
			glColor(r, g, b, 0.0);  glVertex(c.x, c.y + bh, c.z)
		end)
	end
	glLineWidth(1)

	gl.DepthTest(false)
	for i = 1, #clusters do
		if i <= MAX_WORLD_LABELS or i == hoverIdx then
			local c = clusters[i]
			local r, g, b = Severity(c.m)
			local size = clamp(c.radius * 0.30, 34, 90)
			local bh = 140 + clamp(c.m / 8, 0, 420)
			gl.PushMatrix()
			gl.Translate(c.x, c.y + bh + 24, c.z)
			gl.Billboard()
			glColor(r, g, b, 1)
			glText(Fmt(c.m) .. " M", 0, 0, size, "co")
			glColor(0.88, 0.97, 0.75, 0.95)
			glText("~" .. c.n .. " zombies", 0, -size * 0.85, size * 0.6, "co")
			gl.PopMatrix()
		end
	end
	gl.DepthTest(true)
	glBlend(false)
	glColor(1, 1, 1, 1)
end

---------------------------------- DRAWING: MINIMAP ----------------------------

function widget:DrawInMiniMap(sx, sy)
	if #clusters == 0 then return end
	local t = os.clock()
	gl.Texture(false)
	glBlend(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	for i = 1, #clusters do
		local c = clusters[i]
		local r, g, b = Severity(c.m)
		local px, py, pr, asp
		if MINIMAP_UNIT_SPACE then
			px, py = c.x / mapX, 1 - c.z / mapZ
			pr, asp = max(0.012, c.radius / mapX), mapX / mapZ
		else
			px, py = c.x / mapX * sx, sy - c.z / mapZ * sy
			pr, asp = max(4, c.radius / mapX * sx), 1
		end
		local pulse = (t * 0.55 + i * 0.173) % 1
		glColor(r, g, b, 0.30)
		Disc(px, py, pr, 18, asp)
		glLineWidth(i == hoverIdx and 3 or 1.5)
		glColor(r, g, b, i == hoverIdx and 1 or 0.85)
		Ring(px, py, pr, 24, asp)
		glColor(r, g, b, 0.5 * (1 - pulse))
		Ring(px, py, pr * (0.4 + 0.9 * pulse), 24, asp)
	end
	glLineWidth(1)
	glBlend(false)
	glColor(1, 1, 1, 1)
end

---------------------------------- INPUT ---------------------------------------

function widget:IsAbove(x, y)
	local L = layout
	return L ~= nil and InRect(x, y, L.x1, L.y1, L.x2, L.y2)
end

function widget:MousePress(mx, my, button)
	local L = ComputeLayout()
	layout = L
	if not InRect(mx, my, L.x1, L.y1, L.x2, L.y2) then return false end

	if button == 1 then
		local bc = L.btnC
		if InRect(mx, my, bc.x1, bc.y1, bc.x2, bc.y2) then
			collapsed = not collapsed
			return true
		end
		if not collapsed then
			local bm = L.btnM
			if InRect(mx, my, bm.x1, bm.y1, bm.x2, bm.y2) then
				includeAll = not includeAll
				Scan()
				return true
			end
			DetectHover(L, mx, my)
			if hoverIdx and clusters[hoverIdx] then
				GoTo(clusters[hoverIdx].x, clusters[hoverIdx].z)
				return true
			end
			local r = L.radar
			if InRect(mx, my, r.x1, r.y1, r.x2, r.y2) then
				GoTo((mx - r.x1) / (r.x2 - r.x1) * mapX, (r.y2 - my) / (r.y2 - r.y1) * mapZ)
				return true
			end
		end
		dragging = true
		dragOffX, dragOffY = mx - posX, my - posY
	end
	return true
end

function widget:MouseMove(mx, my, dx, dy)
	if dragging then
		posX, posY = mx - dragOffX, my - dragOffY
	end
end

function widget:MouseRelease(mx, my, button)
	dragging = false
	return true
end

function widget:MouseWheel(up, value)
	local L = layout
	if not L then return false end
	local mx, my = spGetMouseState()
	if InRect(mx, my, L.x1, L.y1, L.x2, L.y2) then
		scale = clamp(scale + (up and 0.06 or -0.06), 0.6, 1.8)
		return true
	end
	return false
end

---------------------------------- LIFECYCLE -----------------------------------

function widget:ViewResize()
	vsx, vsy = spGetViewGeometry()
end

function widget:Update(dt)
	local now = os.clock()
	if now - lastScan >= SCAN_INTERVAL then
		lastScan = now
		Scan()
	end
end

function widget:Initialize()
	vsx, vsy = spGetViewGeometry()
	if not posX or not posY then
		local s = max(0.5, scale * vsy / 1080)
		posX = vsx - 290 * s - 24
		posY = vsy - 150 * s
	end
	Scan()
	dispMetal, dispZ = totalMetal, totalZ
end

function widget:GetConfigData()
	return { posX = posX, posY = posY, scale = scale, collapsed = collapsed, includeAll = includeAll }
end

function widget:SetConfigData(data)
	if not data then return end
	posX, posY = data.posX, data.posY
	scale = data.scale or scale
	collapsed = data.collapsed or false
	includeAll = data.includeAll or false
end
