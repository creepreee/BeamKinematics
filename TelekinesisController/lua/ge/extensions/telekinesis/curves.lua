local M = {}

local function clamp01(t)
  if t < 0 then return 0 end
  if t > 1 then return 1 end
  return t
end

local function linear(t)
  return t
end

local function easeIn(t)
  return t * t
end

local function easeOut(t)
  return 1 - (1 - t) * (1 - t)
end

local function easeInOut(t)
  return t * t * (3 - 2 * t)
end

local function cubicBezier(a, b, c, d, t)
  local mt = 1 - t
  return (mt * mt * mt * a)
       + (3 * mt * mt * t * b)
       + (3 * mt * t * t * c)
       + (t * t * t * d)
end

local function cubicBezierDerivative(a, b, c, d, t)
  local mt = 1 - t
  return 3 * mt * mt * (b - a)
       + 6 * mt * t * (c - b)
       + 3 * t * t * (d - c)
end

local function solveBezierYForX(x, x1, y1, x2, y2)
  -- Solve x(t) = x, then return y(t)
  local t = clamp01(x)

  for _ = 1, 8 do
    local xEst = cubicBezier(0, x1, x2, 1, t)
    local dx = xEst - x
    if math.abs(dx) < 1e-5 then break end

    local dEst = cubicBezierDerivative(0, x1, x2, 1, t)
    if math.abs(dEst) < 1e-5 then break end

    t = clamp01(t - dx / dEst)
  end

  local y = cubicBezier(0, y1, y2, 1, t)
  return clamp01(y)
end

local function evaluateBezier(t, mode)
  local p1 = mode.p1 or mode.out or mode.handleOut or mode.start
  local p2 = mode.p2 or mode.in_ or mode.inHandle or mode.handleIn or mode.finish

  if not p1 then p1 = { x = 0.25, y = 0.0 } end
  if not p2 then p2 = { x = 0.75, y = 1.0 } end

  return solveBezierYForX(
    clamp01(t),
    p1.x or 0.25, p1.y or 0.0,
    p2.x or 0.75, p2.y or 1.0
  )
end

function M.evaluate(t, mode)
  t = clamp01(t)

  if type(mode) == "table" then
    if mode.type == "bezier" or mode.p1 or mode.p2 or mode.out or mode.in_ then
      return evaluateBezier(t, mode)
    end
    mode = mode.mode or "linear"
  end

  mode = mode or "linear"

  if mode == "easeIn" then
    return easeIn(t)
  elseif mode == "easeOut" then
    return easeOut(t)
  elseif mode == "easeInOut" then
    return easeInOut(t)
  else
    return linear(t)
  end
end

return M