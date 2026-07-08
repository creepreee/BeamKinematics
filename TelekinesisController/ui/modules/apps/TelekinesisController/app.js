angular.module('beamng.apps')
.directive('telekinesisController', [function () {
  return {
    templateUrl: '/ui/modules/apps/TelekinesisController/app.html',
    replace: false,
    restrict: 'E',
    scope: false,
    controllerAs: 'tk',
    controller: function ($scope, $timeout, $element) {
      var vm = this
      var ext = 'extensions["telekinesis.main"]'
      var fileInput = null

      vm.status = 'Loading'
      vm.selectedIndex = 0
      vm.graphZoom = 1.0
      vm.dirty = false
      vm.showAdvanced = false
      vm.uiVisible = true
      vm.currentTime = 0
      vm.isPlaying = false
      vm.isBaked = false
      vm.bakedCount = 0
      vm.showAllFrames = false
      vm.state = {
        keyframes: [],
        settings: {},
        releaseEnabled: true,
        releaseTime: 11,
        saveFile: ''
      }

      vm.axisOptions = [
        { value: 'x', label: 'X' },
        { value: 'y', label: 'Y' },
        { value: 'z', label: 'Z' }
      ]

      vm.graphAxisOptions = [
        { value: 'z', label: 'Z' },
        { value: 'x', label: 'X' },
        { value: 'y', label: 'Y' },
        { value: 'speed', label: 'Speed' }
      ]

      vm.curveOptions = [
        { value: 'linear', label: 'Linear' },
        { value: 'easeIn', label: 'Ease In' },
        { value: 'easeOut', label: 'Ease Out' },
        { value: 'easeInOut', label: 'Ease In-Out' },
        { value: 'bezier', label: 'Bezier' }
      ]

      vm.settingFields = [
        { key: 'KP_POS', label: 'KP Pos', step: 0.1 },
        { key: 'KD_POS', label: 'KD Pos', step: 0.1 },
        { key: 'KP_ROT', label: 'KP Rot', step: 0.1 },
        { key: 'KD_ROT', label: 'KD Rot', step: 0.1 },
        { key: 'MAX_ACCEL', label: 'Max Accel', step: 0.5 },
        { key: 'MAX_ANG_ACCEL', label: 'Max Ang', step: 0.5 },
        { key: 'GRAVITY_RAMP', label: 'Grav Ramp', step: 0.05 },
        { key: 'FF_DT', label: 'FF Dt', step: 0.005 },
        { key: 'END_HOLD_TIME', label: 'End Hold', step: 0.1 },
        { key: 'DEBUG', label: 'Debug Log', type: 'boolean' }
      ]

      function luaCall (code, callback) {
        bngApi.engineLua(code, function (response) {
          $scope.$evalAsync(function () {
            if (callback) callback(response)
          })
        })
      }

      function extCall (expr, callback) {
        luaCall(ext + '.' + expr, callback)
      }

      function asArray (value) {
        if (!value) return []
        if (Array.isArray(value)) return value
        return Object.keys(value)
          .filter(function (key) { return !isNaN(parseInt(key, 10)) })
          .sort(function (a, b) { return parseInt(a, 10) - parseInt(b, 10) })
          .map(function (key) { return value[key] })
      }

      function numberOr (value, fallback) {
        var n = parseFloat(value)
        return isNaN(n) ? fallback : n
      }

      function clone (obj) {
        return JSON.parse(JSON.stringify(obj))
      }

      var timePollTimer = null
      var playStartWall = 0

      function startTimePoll (startTime) {
        stopTimePoll()
        startTime = startTime || 0
        playStartWall = Date.now() - startTime * 1000
        vm.currentTime = startTime
        scheduleGraphRender()
        timePollTimer = setInterval(function () {
          if (!vm.isPlaying) {
            clearInterval(timePollTimer)
            timePollTimer = null
            return
          }
          vm.currentTime = (Date.now() - playStartWall) / 1000
          scheduleGraphRender()
        }, 50)
      }

      function stopTimePoll () {
        if (timePollTimer) {
          clearInterval(timePollTimer)
          timePollTimer = null
        }
      }

      var graphState = { drag: null, hover: null }
      vm.graphAxis = 'z'

      function scheduleGraphRender () {
        $timeout(renderGraph, 0)
      }

      function getKfValue (kf, axis) {
        if (axis === 'speed') return 0
        var off = kf.off || {}
        return numberOr(off[axis], 0)
      }

      function getFramesForAxis () {
        return (vm.state.keyframes || []).map(function (kf) {
          return {
            time: numberOr(kf.time, 0),
            kf: kf,
            value: getKfValue(kf, vm.graphAxis)
          }
        }).sort(function (a, b) { return a.time - b.time })
      }

      // Horizontal pan offset (in pixels) so zoom CENTERS on the selected keyframe instead
      // of always pinning time 0 to the left edge. Returns the px to subtract from timeToX.
      // Without this, zoomW just stretches the whole curve rightward off-screen and the
      // selected keyframe is never brought into view. Clamped so we never scroll past the
      // start (offset >= 0) or past the end (can't reveal blank space beyond the last frame).
      function getPanOffset (frames, plotW, lastTime) {
        var zoomW = plotW * vm.graphZoom
        if (zoomW <= plotW) return 0            // fully zoomed out: no panning needed
        var sel = frames[vm.selectedIndex] || frames[0]
        var focusT = sel ? sel.time : 0
        // x of the focus time within the (unpanned) zoomed strip, then shift it to plot centre
        var focusX = (focusT / lastTime) * zoomW
        var offset = focusX - plotW / 2
        return Math.max(0, Math.min(offset, zoomW - plotW))
      }

      function getSegmentCurve (i, frames) {
        if (!frames || i >= frames.length - 1) return null
        var kf = frames[i].kf
        var curveObj = (kf.curveMode === 'bezier' && kf.bezier) ? kf.bezier : null
        if (!curveObj) return null
        return {
          p1: { x: numberOr(curveObj.p1 && curveObj.p1.x, 0.25), y: numberOr(curveObj.p1 && curveObj.p1.y, 0.0) },
          p2: { x: numberOr(curveObj.p2 && curveObj.p2.x, 0.75), y: numberOr(curveObj.p2 && curveObj.p2.y, 1.0) }
        }
      }

      function evalBezier (p1, p2, t) {
        t = Math.max(0, Math.min(1, t))
        function cubic (a, b, c, d, u) {
          var mu = 1 - u
          return mu * mu * mu * a + 3 * mu * mu * u * b + 3 * mu * u * u * c + u * u * u * d
        }
        function solveX (x) {
          var u = x
          for (var iter = 0; iter < 8; iter++) {
            var xEst = cubic(0, p1.x, p2.x, 1, u)
            var dx = xEst - x
            if (Math.abs(dx) < 1e-5) break
            var dEst = 3 * (1 - u) * (1 - u) * (p1.x - 0) + 6 * (1 - u) * u * (p2.x - p1.x) + 3 * u * u * (1 - p2.x)
            if (Math.abs(dEst) < 1e-5) break
            u = u - dx / dEst
            u = Math.max(0, Math.min(1, u))
          }
          return Math.max(0, Math.min(1, cubic(0, p1.y, p2.y, 1, u)))
        }
        return solveX(t)
      }

      function evalEasing (t, curveMode) {
        t = Math.max(0, Math.min(1, t))
        if (curveMode === 'linear') return t
        if (curveMode === 'easeIn') return t * t
        if (curveMode === 'easeOut') return 1 - (1 - t) * (1 - t)
        if (curveMode === 'easeInOut') return t * t * (3 - 2 * t)
        return t
      }

      function evaluateSegment (localT, kf) {
        if (kf.curveMode === 'bezier' && kf.bezier) {
          return evalBezier(kf.bezier.p1, kf.bezier.p2, localT)
        }
        return evalEasing(localT, kf.curveMode || 'linear')
      }

      function getAxisDataRange (frames, axis) {
        var minVal = Infinity, maxVal = -Infinity
        frames.forEach(function (f) {
          var v = axis === 'speed' ? 0 : getKfValue(f.kf, axis)
          if (v < minVal) minVal = v
          if (v > maxVal) maxVal = v
        })
        if (axis === 'speed') {
          var speeds = getSegmentSpeeds(frames)
          speeds.forEach(function (s) {
            if (s.speed > maxVal) maxVal = s.speed
            if (s.speed < minVal) minVal = s.speed
          })
        }
        if (Math.abs(maxVal - minVal) < 0.01) {
          maxVal = minVal + 1
          minVal = minVal - 0.5
        }
        var pad = (maxVal - minVal) * 0.15
        return { min: minVal - pad, max: maxVal + pad }
      }

      function getSegmentSpeeds (frames) {
        var speeds = []
        for (var i = 0; i < frames.length - 1; i++) {
          var dt = Math.max(0.001, frames[i + 1].time - frames[i].time)
          var dv = frames[i + 1].value - frames[i].value
          var speed = Math.abs(dv) / dt
          speeds.push({ time: frames[i].time, nextTime: frames[i + 1].time, speed: speed })
        }
        return speeds
      }

      function renderGraph () {
        var canvas = $element[0].querySelector('.telekinesis-speed-graph')
        if (!canvas) return

        var width = canvas.clientWidth || 0
        var height = canvas.clientHeight || 0
        if (width < 10 || height < 10) return

        var ratio = window.devicePixelRatio || 1
        if (canvas.width !== Math.floor(width * ratio) || canvas.height !== Math.floor(height * ratio)) {
          canvas.width = Math.floor(width * ratio)
          canvas.height = Math.floor(height * ratio)
        }

        var ctx = canvas.getContext('2d')
        ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
        ctx.clearRect(0, 0, width, height)

        var pad = { left: 38, right: 10, top: 12, bottom: 20 }
        var plotW = Math.max(1, width - pad.left - pad.right)
        var plotH = Math.max(1, height - pad.top - pad.bottom)

        var frames = getFramesForAxis()
        if (frames.length < 1) return

        var lastTime = Math.max(0.1, frames[frames.length - 1].time)
        var dataRange = getAxisDataRange(frames, vm.graphAxis)
        var minVal = dataRange.min, maxVal = dataRange.max

        var zoomW = plotW * vm.graphZoom
        var panX = getPanOffset(frames, plotW, lastTime)
        function timeToX (t) { return pad.left + (t / lastTime) * zoomW - panX }
        function valToY (v) { return pad.top + plotH - ((v - minVal) / (maxVal - minVal)) * plotH }
        function xToTime (x) { return ((x - pad.left + panX) / zoomW) * lastTime }
        function yToVal (y) { return minVal + ((pad.top + plotH - y) / plotH) * (maxVal - minVal) }
        var minVisibleTime = xToTime(pad.left)
        var maxVisibleTime = xToTime(pad.left + plotW)

        // Grid
        ctx.strokeStyle = 'rgba(190, 205, 214, 0.12)'
        ctx.lineWidth = 1
        for (var gx = 0; gx <= 4; gx++) {
          var x = pad.left + (plotW * gx / 4)
          ctx.beginPath(); ctx.moveTo(x, pad.top); ctx.lineTo(x, pad.top + plotH); ctx.stroke()
        }
        for (var gy = 0; gy <= 3; gy++) {
          var y = pad.top + (plotH * gy / 3)
          ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(pad.left + plotW, y); ctx.stroke()
        }

        // Y axis label
        ctx.fillStyle = 'rgba(237, 242, 244, 0.55)'
        ctx.font = '10px Segoe UI, sans-serif'
        ctx.textAlign = 'right'
        ctx.textBaseline = 'middle'
        ctx.fillText(maxVal.toFixed(1), pad.left - 5, pad.top + 2)
        ctx.fillText(minVal.toFixed(1), pad.left - 5, pad.top + plotH)
        var midVal = (minVal + maxVal) / 2
        ctx.fillText(midVal.toFixed(1), pad.left - 5, pad.top + plotH / 2)
        ctx.textAlign = 'center'
        ctx.textBaseline = 'top'
        ctx.fillText(minVisibleTime.toFixed(1) + 's', pad.left, pad.top + plotH + 4)
        ctx.fillText(maxVisibleTime.toFixed(1) + 's', pad.left + plotW, pad.top + plotH + 4)

        // Speed fill (if showing position axis, draw speed as subtle background)
        if (vm.graphAxis !== 'speed' && frames.length >= 2) {
          var speeds = getSegmentSpeeds(frames)
          var maxSpeed = 0.1
          speeds.forEach(function (s) { if (s.speed > maxSpeed) maxSpeed = s.speed })
          if (maxSpeed > 0.1) {
            ctx.fillStyle = 'rgba(90, 204, 184, 0.07)'
            speeds.forEach(function (seg) {
              var x1 = timeToX(seg.time)
              var x2 = timeToX(seg.nextTime)
              var sh = (seg.speed / maxSpeed) * plotH
              ctx.fillRect(x1, pad.top + plotH - sh, Math.max(1, x2 - x1), sh)
            })
          }
        }

        // Draw value curve
        if (frames.length >= 2) {
          ctx.strokeStyle = 'rgba(90, 204, 184, 0.85)'
          ctx.lineWidth = 2
          ctx.beginPath()
          var first = true
          for (var si = 0; si < frames.length - 1; si++) {
            var k1 = frames[si], k2 = frames[si + 1]
            var dt = Math.max(0.001, k2.time - k1.time)
            var dv = k2.value - k1.value
            var steps = Math.max(20, Math.floor(dt * 120))
            for (var s = 0; s <= steps; s++) {
              var localT = s / steps
              var easedT = evaluateSegment(localT, k1.kf)
              var t = k1.time + localT * dt
              var v = k1.value + dv * easedT
              var cx = timeToX(t), cy = valToY(v)
              if (first) { ctx.moveTo(cx, cy); first = false }
              else ctx.lineTo(cx, cy)
            }
          }
          ctx.stroke()

          // Speed graph mode: draw filled speed area instead
          if (vm.graphAxis === 'speed' && speeds) {
            // redraw as speed
          }
        }

        // Draw keyframe points
        var selIdx = vm.selectedIndex
        frames.forEach(function (f, idx) {
          var cx = timeToX(f.time)
          var cy = valToY(f.value)
          var isSel = (idx === selIdx)
          var size = isSel ? 7 : 5

          ctx.beginPath()
          ctx.moveTo(cx, cy - size)
          ctx.lineTo(cx + size * 0.7, cy)
          ctx.lineTo(cx, cy + size)
          ctx.lineTo(cx - size * 0.7, cy)
          ctx.closePath()

          if (isSel) {
            ctx.fillStyle = 'rgba(240, 176, 41, 0.9)'
            ctx.strokeStyle = 'rgba(240, 176, 41, 0.5)'
            ctx.lineWidth = 2
            ctx.fill()
            ctx.stroke()
          } else {
            ctx.fillStyle = 'rgba(237, 242, 244, 0.6)'
            ctx.strokeStyle = 'rgba(237, 242, 244, 0.3)'
            ctx.lineWidth = 1
            ctx.fill()
            ctx.stroke()
          }
        })

        // Draw bezier handles for the selected segment
        if (selIdx >= 0 && selIdx < frames.length - 1) {
          var segCurve = getSegmentCurve(selIdx, frames)
          if (segCurve) {
            var k1 = frames[selIdx], k2 = frames[selIdx + 1]
            var segDt = Math.max(0.001, k2.time - k1.time)
            var segDv = k2.value - k1.value

            var h1x = timeToX(k1.time + segDt * segCurve.p1.x)
            var h1y = valToY(k1.value + segDv * segCurve.p1.y)
            var h2x = timeToX(k1.time + segDt * segCurve.p2.x)
            var h2y = valToY(k1.value + segDv * segCurve.p2.y)
            var k1x = timeToX(k1.time), k1y = valToY(k1.value)
            var k2x = timeToX(k2.time), k2y = valToY(k2.value)

            // Handle lines (dashed)
            ctx.strokeStyle = 'rgba(190, 205, 214, 0.35)'
            ctx.lineWidth = 1
            ctx.setLineDash([3, 3])
            ctx.beginPath(); ctx.moveTo(k1x, k1y); ctx.lineTo(h1x, h1y); ctx.stroke()
            ctx.beginPath(); ctx.moveTo(k2x, k2y); ctx.lineTo(h2x, h2y); ctx.stroke()
            ctx.setLineDash([])

            // Handle circles
            function drawHandle (hx, hy, label) {
              ctx.beginPath()
              ctx.arc(hx, hy, 6, 0, Math.PI * 2)
              ctx.fillStyle = 'rgba(90, 204, 184, 0.85)'
              ctx.fill()
              ctx.strokeStyle = 'rgba(237, 242, 244, 0.5)'
              ctx.lineWidth = 1.5
              ctx.stroke()
              ctx.fillStyle = 'rgba(237, 242, 244, 0.5)'
              ctx.font = '8px sans-serif'
              ctx.textAlign = 'center'
              ctx.textBaseline = 'bottom'
              ctx.fillText(label, hx, hy - 8)
            }
            drawHandle(h1x, h1y, 'out')
            drawHandle(h2x, h2y, 'in')
          }
        }

        // Draw playhead (green time indicator line at 50% opacity)
        if (vm.currentTime > 0 && frames.length >= 1) {
          var phX = timeToX(vm.currentTime)
          if (phX >= pad.left && phX <= pad.left + plotW) {
            ctx.strokeStyle = 'rgba(90, 204, 184, 0.5)'
            ctx.lineWidth = 2
            ctx.beginPath()
            ctx.moveTo(phX, pad.top)
            ctx.lineTo(phX, pad.top + plotH)
            ctx.stroke()
            // Small diamond at top of playhead
            ctx.beginPath()
            ctx.moveTo(phX, pad.top - 4)
            ctx.lineTo(phX + 4, pad.top)
            ctx.lineTo(phX, pad.top + 4)
            ctx.lineTo(phX - 4, pad.top)
            ctx.closePath()
            ctx.fillStyle = 'rgba(90, 204, 184, 0.7)'
            ctx.fill()
          }
        }
      }

      function findNearest (mx, my, threshold) {
        threshold = threshold || 12
        var canvas = $element[0].querySelector('.telekinesis-speed-graph')
        if (!canvas) return null
        var rect = canvas.getBoundingClientRect()
        var scaleX = canvas.clientWidth / Math.max(1, canvas.clientWidth)
        var scaleY = canvas.clientHeight / Math.max(1, canvas.clientHeight)
        var mx2 = mx, my2 = my

        var pad = { left: 38, top: 12 }
        var width = canvas.clientWidth || 0
        var height = canvas.clientHeight || 0
        var plotW = Math.max(1, width - pad.left - 10)
        var plotH = Math.max(1, height - pad.top - 20)
        var frames = getFramesForAxis()
        if (frames.length < 1) return null
        var lastTime = Math.max(0.1, frames[frames.length - 1].time)
        var dataRange = getAxisDataRange(frames, vm.graphAxis)

        var zoomW = plotW * vm.graphZoom
        var panX = getPanOffset(frames, plotW, lastTime)
        function timeToX (t) { return pad.left + (t / lastTime) * zoomW - panX }
        function valToY (v) { return pad.top + plotH - ((v - dataRange.min) / (dataRange.max - dataRange.min)) * plotH }

        // Check handles first (selected segment only)
        var selIdx = vm.selectedIndex
        if (selIdx >= 0 && selIdx < frames.length - 1) {
          var segCurve = getSegmentCurve(selIdx, frames)
          if (segCurve) {
            var k1 = frames[selIdx], k2 = frames[selIdx + 1]
            var segDt = Math.max(0.001, k2.time - k1.time)
            var segDv = k2.value - k1.value
            var handles = [
              { type: 'out', idx: selIdx, x: timeToX(k1.time + segDt * segCurve.p1.x), y: valToY(k1.value + segDv * segCurve.p1.y) },
              { type: 'in', idx: selIdx, x: timeToX(k1.time + segDt * segCurve.p2.x), y: valToY(k1.value + segDv * segCurve.p2.y) }
            ]
            for (var hi = 0; hi < handles.length; hi++) {
              var h = handles[hi]
              var dx = mx2 - h.x, dy = my2 - h.y
              if (dx * dx + dy * dy < threshold * threshold) {
                return { type: 'handle', handleType: h.type, keyframeIdx: h.idx }
              }
            }
          }
        }

        // Check keyframe points
        for (var fi = 0; fi < frames.length; fi++) {
          var cx = timeToX(frames[fi].time)
          var cy = valToY(frames[fi].value)
          var dx = mx2 - cx, dy = my2 - cy
          if (dx * dx + dy * dy < threshold * threshold) {
            return { type: 'keyframe', index: fi }
          }
        }

        return null
      }

      vm.graphMouseDown = function ($event) {
        var rect = $event.target.getBoundingClientRect()
        var mx = $event.clientX - rect.left
        var my = $event.clientY - rect.top
        var hit = findNearest(mx, my)
        if (hit) {
          if (hit.type === 'keyframe') {
            vm.selectKeyframe(hit.index)
          } else if (hit.type === 'handle') {
            graphState.drag = { handleType: hit.handleType, keyframeIdx: hit.keyframeIdx, startMX: mx, startMY: my }
            $event.preventDefault()
          }
          return
        }

        // Not hitting a keyframe/handle — scrub the playhead.
        // Stop the poll timer so it doesn't fight the scrub position.
        // If the engine was stopped, activate it so onUpdate responds.
        stopTimePoll()
        vm._wasPlaying = vm.isPlaying
        if (!vm.isPlaying) {
          extCall('setActive(true)')
        }
        var canvas = $event.target
        var width = canvas.clientWidth || 0
        var height = canvas.clientHeight || 0
        var pad = { left: 38, top: 12 }
        var plotW = Math.max(1, width - pad.left - 10)
        var frames = getFramesForAxis()
        if (frames.length < 1) return
        var lastTime = Math.max(0.1, frames[frames.length - 1].time)
        var zoomW = plotW * vm.graphZoom
        var panX = getPanOffset(frames, plotW, lastTime)
        var t = ((mx - pad.left + panX) / zoomW) * lastTime
        t = Math.max(0, Math.min(t, lastTime))
        vm.currentTime = t
        extCall('setElapsedTime(' + t + ')')
        scheduleGraphRender()
        graphState.drag = { scrub: true, lastTime: lastTime, zoomW: zoomW, panX: panX, padLeft: pad.left }
        $event.preventDefault()
      }

      vm.graphMouseMove = function ($event) {
        if (!graphState.drag) return

        if (graphState.drag.scrub) {
          var rect = $event.target.getBoundingClientRect()
          var mx = $event.clientX - rect.left
          var gd = graphState.drag
          var t = ((mx - gd.padLeft + gd.panX) / gd.zoomW) * gd.lastTime
          t = Math.max(0, Math.min(t, gd.lastTime))
          vm.currentTime = t
          extCall('setElapsedTime(' + t + ')')
          scheduleGraphRender()
          return
        }

        var rect = $event.target.getBoundingClientRect()
        var mx = $event.clientX - rect.left
        var my = $event.clientY - rect.top

        var canvas = $event.target
        var width = canvas.clientWidth, height = canvas.clientHeight
        var pad = { left: 38, top: 12 }
        var plotW = Math.max(1, width - pad.left - 10)
        var plotH = Math.max(1, height - pad.top - 20)

        var frames = getFramesForAxis()
        var selIdx = graphState.drag.keyframeIdx
        if (selIdx < 0 || selIdx >= frames.length - 1) { graphState.drag = null; return }
        var k1 = frames[selIdx], k2 = frames[selIdx + 1]
        var lastTime = Math.max(0.1, frames[frames.length - 1].time)
        var dataRange = getAxisDataRange(frames, vm.graphAxis)

        var zoomW2 = plotW * vm.graphZoom
        var panX2 = getPanOffset(frames, plotW, lastTime)
        function xToTime (x) { return ((x - pad.left + panX2) / zoomW2) * lastTime }
        function yToVal (y) { return dataRange.min + ((pad.top + plotH - y) / plotH) * (dataRange.max - dataRange.min) }

        var segDt = Math.max(0.001, k2.time - k1.time)
        var segDv = k2.value - k1.value

        var hitTime = xToTime(mx)
        var hitVal = yToVal(my)

        var px = Math.max(0, Math.min(1, (hitTime - k1.time) / segDt))
        var py = (segDv !== 0) ? Math.max(0, Math.min(1, (hitVal - k1.value) / segDv)) : 0.5

        var kf = k1.kf
        if (!kf.bezier) {
          kf.bezier = { p1: { x: 0.25, y: 0.0 }, p2: { x: 0.75, y: 1.0 } }
        }
        if (graphState.drag.handleType === 'out') {
          kf.bezier.p1.x = Math.round(px * 100) / 100
          kf.bezier.p1.y = Math.round(py * 100) / 100
        } else {
          kf.bezier.p2.x = Math.round(px * 100) / 100
          kf.bezier.p2.y = Math.round(py * 100) / 100
        }
        if (kf.curveMode !== 'bezier') kf.curveMode = 'bezier'
        renderGraph()
      }

      vm.graphMouseUp = function ($event) {
        if (graphState.drag) {
          if (graphState.drag.scrub) {
            var scrubbedTime = vm.currentTime
            graphState.drag = null
            if (!vm._wasPlaying) {
              extCall('setActive(false)')
            } else {
              startTimePoll(scrubbedTime)
            }
            return
          }
          graphState.drag = null
          vm.markDirty()
        }
      }

      vm.changeAxis = function () {
        scheduleGraphRender()
      }

      vm.changeZoom = function () {
        scheduleGraphRender()
      }

      // Reset zoom to fit the whole timeline (the "Fit" button).
      vm.fitZoom = function () {
        vm.graphZoom = 1.0
        scheduleGraphRender()
      }

      // Human-readable line under the graph: which keyframe is selected + its time/value,
      // so the user knows what zoom is following and what the handles will edit.
      vm.selectionInfo = function () {
        var kf = vm.state.keyframes[vm.selectedIndex]
        if (!kf) return 'Click a keyframe to select it.'
        var axis = vm.graphAxis === 'speed' ? 'Z' : vm.graphAxis.toUpperCase()
        var val = vm.graphAxis === 'speed' ? '' : ('  ' + axis + '=' + numberOr(getKfValue(kf, vm.graphAxis), 0).toFixed(2) + 'm')
        return 'Keyframe ' + (vm.selectedIndex + 1) + ' of ' + vm.state.keyframes.length +
               '  @ ' + numberOr(kf.time, 0).toFixed(2) + 's' + val
      }

      function normalizeCurveForUi (kf) {
        if (typeof kf.curve === 'object' && kf.curve) {
          kf.curveMode = 'bezier'
          kf.bezier = {
            p1: {
              x: numberOr(kf.curve.p1 && kf.curve.p1.x, 0.25),
              y: numberOr(kf.curve.p1 && kf.curve.p1.y, 0.0)
            },
            p2: {
              x: numberOr(kf.curve.p2 && kf.curve.p2.x, 0.75),
              y: numberOr(kf.curve.p2 && kf.curve.p2.y, 1.0)
            }
          }
        } else {
          kf.curveMode = kf.curve || 'linear'
          kf.bezier = kf.bezier || { p1: { x: 0.25, y: 0.0 }, p2: { x: 0.75, y: 1.0 } }
        }
      }

      function normalizeKeyframeForUi (kf) {
        kf.off = kf.off || { x: kf.x || 0, y: kf.y || 0, z: kf.z || 0 }
        kf.rot = kf.rot || { axis: 'z', deg: 0 }
        kf.time = numberOr(kf.time, 0)
        kf.off.x = numberOr(kf.off.x, 0)
        kf.off.y = numberOr(kf.off.y, 0)
        kf.off.z = numberOr(kf.off.z, 0)
        kf.rot.axis = kf.rot.axis || 'z'
        kf.rot.deg = numberOr(kf.rot.deg, 0)
        normalizeCurveForUi(kf)
        return kf
      }

      function receiveState (state, status) {
        if (!state) {
          vm.status = status || 'No state'
          return
        }

        vm.state = {
          keyframes: asArray(state.keyframes).map(normalizeKeyframeForUi),
          settings: state.settings || {},
          releaseEnabled: state.releaseEnabled !== false,
          releaseTime: numberOr(state.releaseTime, 0),
          saveFile: state.saveFile || ''
        }

        if (vm.isPlaying !== (state.active === true)) {
          vm.isPlaying = state.active === true
          if (!vm.isPlaying) stopTimePoll()
        }

        vm.isBaked = state.isBaked === true
        vm.bakedCount = state.bakedCount || 0

        if (vm.state.keyframes.length === 0) {
          vm.state.keyframes.push(normalizeKeyframeForUi({
            time: 0,
            off: { x: 0, y: 0, z: 0 },
            rot: { axis: 'z', deg: 0 },
            curve: 'linear'
          }))
        }

        vm.selectedIndex = Math.max(0, Math.min(vm.selectedIndex, vm.state.keyframes.length - 1))
        vm.dirty = false
        vm.status = status || 'Ready'
        scheduleGraphRender()
      }

      function keyframesForLua () {
        return vm.state.keyframes
          .map(function (kf) {
            var out = {
              time: numberOr(kf.time, 0),
              off: {
                x: numberOr(kf.off.x, 0),
                y: numberOr(kf.off.y, 0),
                z: numberOr(kf.off.z, 0)
              },
              rot: {
                axis: kf.rot.axis || 'z',
                deg: numberOr(kf.rot.deg, 0)
              },
              curve: kf.curveMode
            }

            if (kf.curveMode === 'bezier') {
              out.curve = {
                type: 'bezier',
                p1: {
                  x: numberOr(kf.bezier.p1.x, 0.25),
                  y: numberOr(kf.bezier.p1.y, 0.0)
                },
                p2: {
                  x: numberOr(kf.bezier.p2.x, 0.75),
                  y: numberOr(kf.bezier.p2.y, 1.0)
                }
              }
            }

            return out
          })
          .sort(function (a, b) { return a.time - b.time })
      }

      function uiStateForLua () {
        return {
          version: 1,
          keyframes: keyframesForLua(),
          settings: vm.state.settings,
          releaseEnabled: vm.state.releaseEnabled === true,
          releaseTime: vm.state.releaseEnabled ? numberOr(vm.state.releaseTime, 0) : false
        }
      }

      vm.markDirty = function () {
        vm.dirty = true
        vm.status = 'Edited'
        scheduleGraphRender()
      }

      vm.changeCurve = function (kf) {
        if (kf.curveMode === 'bezier') {
          if (!kf.bezier) kf.bezier = { p1: { x: 0.25, y: 0.0 }, p2: { x: 0.75, y: 1.0 } }
          kf.bezier.p1 = kf.bezier.p1 || { x: 0.25, y: 0.0 }
          kf.bezier.p2 = kf.bezier.p2 || { x: 0.75, y: 1.0 }
        }
        vm.markDirty()
      }

      vm.selectKeyframe = function (index) {
        vm.selectedIndex = index
        scheduleGraphRender()
      }

      vm.addKeyframe = function () {
        var source = vm.state.keyframes[vm.selectedIndex] || vm.state.keyframes[vm.state.keyframes.length - 1]
        var kf = source ? clone(source) : {
          time: 0,
          off: { x: 0, y: 0, z: 0 },
          rot: { axis: 'z', deg: 0 },
          curveMode: 'linear',
          bezier: { p1: { x: 0.25, y: 0.0 }, p2: { x: 0.75, y: 1.0 } }
        }
        kf.time = numberOr(kf.time, 0) + 1
        vm.state.keyframes.push(normalizeKeyframeForUi(kf))
        vm.selectedIndex = vm.state.keyframes.length - 1
        vm.markDirty()
      }

      vm.duplicateKeyframe = function () {
        if (vm.selectedIndex < 0) return
        var kf = clone(vm.state.keyframes[vm.selectedIndex])
        kf.time = numberOr(kf.time, 0) + 0.5
        vm.state.keyframes.push(normalizeKeyframeForUi(kf))
        vm.selectedIndex = vm.state.keyframes.length - 1
        vm.markDirty()
      }

      vm.deleteKeyframe = function (index) {
        if (vm.state.keyframes.length <= 1) return
        vm.state.keyframes.splice(index, 1)
        vm.selectedIndex = Math.max(0, Math.min(index, vm.state.keyframes.length - 1))
        vm.markDirty()
      }

      vm.refresh = function () {
        extCall('getUiState()', function (state) {
          receiveState(state, 'Refreshed')
        })
      }

      vm.apply = function (callback) {
        var cmd = 'applyUiState(' + bngApi.serializeToLua(uiStateForLua()) + ')'
        extCall(cmd, function (state) {
          receiveState(state, 'Applied')
          if (callback) callback()
        })
      }

      vm.play = function () {
        vm.apply(function () {
          extCall('play()', function () {
            vm.status = 'Playing'
            vm.isPlaying = true
            startTimePoll()
          })
        })
      }

      vm.stop = function () {
        vm.isPlaying = false
        stopTimePoll()
        extCall('stop()', function () {
          vm.status = 'Stopped'
        })
      }

      vm.reload = function () {
        vm.status = 'Reloading'
        luaCall('extensions.reload("telekinesis.main")', function () {
          vm.refresh()
        })
        $timeout(vm.refresh, 250)
      }

      vm.savePreset = function () {
        vm.apply(function () {
          extCall('savePreset()', function (result) {
            receiveState(result && result.state, result && result.ok ? 'Saved JSON' : 'Save failed')
          })
        })
      }

      vm.loadPreset = function () {
        extCall('loadPreset()', function (result) {
          receiveState(result && result.state, result && result.ok ? 'Loaded JSON' : 'No saved JSON')
        })
      }

      // Load the Blender-exported animation_data.lua and immediately play it.
      // The Lua side re-reads the file from disk (clears the require cache), offsets
      // the keyframes to the car's current position on the next frame, and runs.
      vm.loadAnimation = function () {
        vm.status = 'Loading animation'
        vm.showAllFrames = false
        extCall('loadAnimationData()', function (result) {
          if (result && result.ok) {
            if (result.state) receiveState(result.state, null)
            vm.status = 'Loaded ' + (result.count || 0) + ' keyframes'
            extCall('play()', function () {
              vm.status = 'Playing animation_data'
              vm.isPlaying = true
              startTimePoll()
            })
          } else {
            vm.status = (result && result.error) || 'No animation_data.lua'
          }
        })
      }

      vm.toggleShowFrames = function () {
        vm.showAllFrames = !vm.showAllFrames
        extCall('toggleShowBakedFrames(' + (vm.showAllFrames ? 'true' : 'false') + ')', function (state) {
          if (state) receiveState(state, vm.showAllFrames ? 'Showing all ' + vm.bakedCount + ' frames' : 'Summary')
        })
      }

      vm.openJsonFile = function () {
        if (!fileInput) {
          fileInput = $element[0].querySelector('.telekinesis-file-input')
        }
        if (!fileInput) {
          vm.status = 'File picker missing'
          return
        }
        fileInput.value = ''
        fileInput.click()
      }

      function importJsonData (data) {
        var imported = data && data.state ? data.state : data
        if (Array.isArray(imported)) {
          imported = { keyframes: imported }
        }
        if (!imported || typeof imported !== 'object') {
          vm.status = 'Bad JSON'
          return
        }
        if (!imported.settings) imported.settings = clone(vm.state.settings || {})
        if (imported.releaseEnabled === undefined) imported.releaseEnabled = vm.state.releaseEnabled
        if (imported.releaseTime === undefined) imported.releaseTime = vm.state.releaseTime
        receiveState(imported, 'Imported JSON')
        vm.apply()
      }

      function handleFileChange (event) {
        var file = event.target.files && event.target.files[0]
        if (!file) return

        var reader = new FileReader()
        reader.onload = function () {
          $scope.$evalAsync(function () {
            try {
              importJsonData(JSON.parse(reader.result))
            } catch (err) {
              vm.status = 'Bad JSON'
            }
          })
        }
        reader.onerror = function () {
          $scope.$evalAsync(function () {
            vm.status = 'Read failed'
          })
        }
        reader.readAsText(file)
      }

      vm.resetDefaults = function () {
        extCall('resetDefaults()', function (state) {
          receiveState(state, 'Defaults')
        })
      }

      vm.toggleUI = function () {
        vm.uiVisible = !vm.uiVisible
      }

      function onKeyDown (e) {
        var key = e.key || e.keyCode
        if (key === 'y' || key === 'Y' || key === 89) {
          var t = e.target
          if (t && (t.tagName === 'INPUT' || t.tagName === 'SELECT' || t.tagName === 'MD-SELECT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return
          $scope.$evalAsync(vm.toggleUI)
        }
      }
      // Attach on BOTH window and document, in the CAPTURE phase. In-game the 3D viewport
      // grabs keyboard focus, so a plain document/bubble listener frequently never fires -
      // capturing on window is the most reliable channel the UI overlay can hook. The toolbar
      // hide button (Y) is the guaranteed fallback if the game still swallows the key.
      window.addEventListener('keydown', onKeyDown, true)
      document.addEventListener('keydown', onKeyDown, true)

      luaCall('extensions.load("telekinesis.main")', function () {
        vm.refresh()
      })
      $timeout(vm.refresh, 250)
      $timeout(function () {
        fileInput = $element[0].querySelector('.telekinesis-file-input')
        if (fileInput) fileInput.addEventListener('change', handleFileChange)
        scheduleGraphRender()
      }, 0)

      $scope.$on('$destroy', function () {
        stopTimePoll()
        if (fileInput) fileInput.removeEventListener('change', handleFileChange)
        window.removeEventListener('keydown', onKeyDown, true)
        document.removeEventListener('keydown', onKeyDown, true)
        vm.status = 'Closed'
      })
    }
  }
}])
