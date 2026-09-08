import QtQuick
import "Freq.js" as Freq

// Spectrum plot over a waterfall, fed by an FftStream. Click to tune,
// scroll to step. Colours come from the theme: the waterfall runs from
// the background through the accent to yellow and red.
Item {
    id: view
    required property var stream
    required property var theme
    property var bandplan: []
    property int step: 100000
    property real floorDb: -100
    property real ceilDb: -20
    property int plotHeight: 110
    signal tuneRequested(int hz)
    signal stepRequested(int delta)
    readonly property var frame: stream.frame

    // Colour lookup for the waterfall, rebuilt when the theme changes.
    property var lut: []
    function buildLut() {
        var stops = [[0, theme.background], [0.45, theme.accent], [0.75, theme.yellow], [1, theme.red]];
        var table = [];
        for (var i = 0; i < 256; i++) {
            var t = i / 255, k = 0;
            while (k < stops.length - 2 && t > stops[k + 1][0]) k++;
            var a = stops[k], b = stops[k + 1], f = (t - a[0]) / (b[0] - a[0]);
            var ca = Qt.color(a[1]), cb = Qt.color(b[1]);
            // CSS strings: the waterfall paints with fillRect runs, because
            // putImageData is a no-op on Quickshell's canvas (tested).
            table.push("rgb(" + Math.round(255 * (ca.r + (cb.r - ca.r) * f)) + "," + Math.round(255 * (ca.g + (cb.g - ca.g) * f)) + "," + Math.round(255 * (ca.b + (cb.b - ca.b) * f)) + ")");
        }
        lut = table;
    }
    onThemeChanged: { buildLut(); plot.requestPaint(); waterfall.clear(); }
    Component.onCompleted: buildLut()

    // Auto-range, snapped and hysteretic. Lerping towards a target every
    // frame made the whole trace and its grid crawl about, which reads as
    // jitter; the signal moves, the axis should not. Targets are rounded to
    // 5 dB and only adopted once they are a full step away, so the axis sits
    // still for long stretches and then steps once.
    property bool ranged: false
    function autoRange(bins) {
        var sorted = bins.slice().sort((a, b) => a - b);
        var lo = Math.round((sorted[Math.floor(sorted.length * 0.1)] - 6) / 5) * 5;
        var hi = Math.round((sorted[sorted.length - 1] + 4) / 5) * 5;
        hi = Math.max(hi, lo + 30);
        if (!ranged) { floorDb = lo; ceilDb = hi; ranged = true; return; }
        if (Math.abs(lo - floorDb) >= 5) floorDb = lo;
        if (Math.abs(hi - ceilDb) >= 5) ceilDb = hi;
    }
    function xToHz(x) {
        if (!frame) return 0;
        return Math.round(frame.center - frame.rate / 2 + x / width * frame.rate);
    }
    function hzToX(hz) { return frame ? (hz - (frame.center - frame.rate / 2)) / frame.rate * width : 0; }
    function niceStep(span) {
        var raw = span / 6, mag = Math.pow(10, Math.floor(Math.log10(raw)));
        for (var m of [1, 2, 2.5, 5, 10]) if (raw <= m * mag) return m * mag;
        return 10 * mag;
    }
    Connections {
        target: view.stream
        function onFrameReady() {
            if (!view.frame) return;
            view.autoRange(view.frame.bins);
            plot.requestPaint();
            waterfall.advance();
        }
    }

    Canvas {
        id: plot
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: view.plotHeight
        renderStrategy: Canvas.Cooperative
        onPaint: {
            var ctx = getContext("2d"), w = width, h = height, f = view.frame;
            ctx.reset();
            ctx.fillStyle = Qt.alpha(view.theme.background, .5);
            ctx.fillRect(0, 0, w, h);
            if (!f) return;
            var lo = f.center - f.rate / 2, span = f.rate;
            // Bandplan bars along the top.
            ctx.font = "9px " + view.theme.font;
            for (var band of view.bandplan) {
                if (band.stop < lo || band.start > lo + span) continue;
                var x0 = Math.max(0, view.hzToX(band.start)), x1 = Math.min(w, view.hzToX(band.stop));
                ctx.fillStyle = band.color.length === 9 ? "#" + band.color.slice(3) : band.color;
                ctx.globalAlpha = .35; ctx.fillRect(x0, 0, x1 - x0, 4); ctx.globalAlpha = 1;
                if (x1 - x0 > ctx.measureText(band.name).width + 6) { ctx.fillStyle = view.theme.foreground; ctx.globalAlpha = .7; ctx.fillText(band.name, x0 + 3, 13); ctx.globalAlpha = 1; }
            }
            // Passband of the tuned channel.
            var px0 = view.hzToX(f.freq - f.bw / 2), px1 = view.hzToX(f.freq + f.bw / 2);
            ctx.fillStyle = Qt.alpha(view.theme.accent, .12);
            ctx.fillRect(px0, 0, Math.max(2, px1 - px0), h);
            // Grid and frequency labels.
            var tick = view.niceStep(span);
            ctx.strokeStyle = Qt.alpha(view.theme.foreground, .12);
            ctx.fillStyle = Qt.alpha(view.theme.foreground, .55);
            ctx.lineWidth = 1;
            for (var hz = Math.ceil(lo / tick) * tick; hz <= lo + span; hz += tick) {
                var x = Math.round(view.hzToX(hz)) + .5;
                ctx.beginPath(); ctx.moveTo(x, 16); ctx.lineTo(x, h); ctx.stroke();
                ctx.fillText(Freq.label(hz).replace(" MHz", ""), x + 3, h - 4);
            }
            for (var db = Math.ceil(view.floorDb / 10) * 10; db < view.ceilDb; db += 10) {
                var y = Math.round(h - (db - view.floorDb) / (view.ceilDb - view.floorDb) * (h - 16)) + .5;
                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
                if (y > 26) ctx.fillText(db + " dB", 3, y - 2);   // keep clear of the bandplan strip
            }
            // The trace.
            var n = f.bins.length, range = view.ceilDb - view.floorDb;
            ctx.beginPath();
            ctx.moveTo(0, h);
            for (var i = 0; i < n; i++) {
                var v = (f.bins[i] - view.floorDb) / range;
                ctx.lineTo(i / (n - 1) * w, h - Math.max(0, Math.min(1, v)) * (h - 16));
            }
            ctx.lineTo(w, h);
            ctx.closePath();
            ctx.fillStyle = Qt.alpha(view.theme.accent, .18);
            ctx.fill();
            ctx.strokeStyle = view.theme.accent;
            ctx.lineWidth = 1.2;
            ctx.beginPath();
            for (var j = 0; j < n; j++) {
                var vv = (f.bins[j] - view.floorDb) / range, yy = h - Math.max(0, Math.min(1, vv)) * (h - 16);
                if (j === 0) ctx.moveTo(0, yy); else ctx.lineTo(j / (n - 1) * w, yy);
            }
            ctx.stroke();
            // Tuned frequency marker.
            var tx = Math.round(view.hzToX(f.freq)) + .5;
            ctx.strokeStyle = view.theme.red;
            ctx.beginPath(); ctx.moveTo(tx, 0); ctx.lineTo(tx, h); ctx.stroke();
        }
    }
    // Waterfall: a ring buffer, never a copy. Each frame writes one row into
    // a canvas at a decreasing index, and two ShaderEffectSource views show
    // the two slices in order with the newest at the top. Copy-based
    // scrolling was tried three ways (a canvas drawn onto itself, and two
    // canvases ping-ponging, under both render strategies) and every one
    // smeared or dropped rows, which is what made the waterfall jump. A
    // marker row every 15 frames measured 30 device pixels apart here and
    // 60 with unpredictable doubling in all three copying versions.
    Item {
        id: waterfall
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: plot.bottom
        anchors.bottom: parent.bottom
        clip: true
        readonly property int rows: Math.max(2, Math.floor(height))
        property int writeIdx: rows - 1
        property int newest: rows - 1
        function clear() { ring.primed = false; ring.requestPaint(); }
        function advance() { ring.requestPaint(); }
        onRowsChanged: clear()
        onWidthChanged: clear()

        Canvas {
            id: ring
            width: waterfall.width
            height: waterfall.height
            renderStrategy: Canvas.Immediate
            property bool primed: false
            onPaint: {
                var ctx = getContext("2d"), w = Math.floor(width), h = waterfall.rows;
                if (w < 2 || h < 2) return;
                if (!primed) {
                    ctx.reset();
                    ctx.fillStyle = view.theme.background;
                    ctx.fillRect(0, 0, w, h);
                    primed = true;
                    waterfall.writeIdx = h - 1;
                    waterfall.newest = h - 1;
                }
                var f = view.frame, lut = view.lut;
                if (!f || lut.length !== 256) return;
                var y = waterfall.writeIdx, n = f.bins.length, range = view.ceilDb - view.floorDb;
                // Runs of equal colour; the peak over the bins that map onto
                // each pixel column, so narrow carriers survive downsampling.
                var runStart = 0, runV = -1;
                for (var x = 0; x <= w; x++) {
                    var v = -1;
                    if (x < w) {
                        var b0 = Math.floor(x / w * n), b1 = Math.max(b0 + 1, Math.floor((x + 1) / w * n)), peak = -1e9;
                        for (var b = b0; b < b1 && b < n; b++) if (f.bins[b] > peak) peak = f.bins[b];
                        v = Math.max(0, Math.min(255, Math.round((peak - view.floorDb) / range * 255)));
                    }
                    if (v !== runV) {
                        if (runV >= 0) { ctx.fillStyle = lut[runV]; ctx.fillRect(runStart, y, x - runStart, 1); }
                        runStart = x; runV = v;
                    }
                }
                // The tuned frequency goes into the row itself, so the trail
                // shows where the receiver has been.
                ctx.fillStyle = Qt.alpha(view.theme.red, .75);
                ctx.fillRect(Math.round(view.hzToX(f.freq)), y, 1, 1);
                waterfall.newest = y;
                waterfall.writeIdx = y === 0 ? h - 1 : y - 1;
            }
        }
        ShaderEffectSource {
            sourceItem: ring
            hideSource: true
            live: true
            y: 0
            width: waterfall.width
            height: waterfall.rows - waterfall.newest
            sourceRect: Qt.rect(0, waterfall.newest, waterfall.width, waterfall.rows - waterfall.newest)
        }
        ShaderEffectSource {
            sourceItem: ring
            live: true
            visible: height > 0
            y: waterfall.rows - waterfall.newest
            width: waterfall.width
            height: waterfall.newest
            sourceRect: Qt.rect(0, 0, waterfall.width, waterfall.newest)
        }
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.CrossCursor
        hoverEnabled: true
        onClicked: mouse => {
            var hz = view.xToHz(mouse.x), unit = view.step >= 1000 ? 1000 : 100;
            view.tuneRequested(Math.round(hz / unit) * unit);
        }
        onWheel: wheel => view.stepRequested(wheel.angleDelta.y > 0 ? 1 : -1)
        Rectangle {
            visible: parent.containsMouse && !!view.frame
            x: Math.min(parent.width - width - 4, parent.mouseX + 10); y: 18
            width: hover.implicitWidth + 8; height: hover.implicitHeight + 4
            color: Qt.alpha(view.theme.background, .9)
            Text { id: hover; anchors.centerIn: parent; color: view.theme.foreground; font.family: view.theme.font; font.pixelSize: 10; text: Freq.label(view.xToHz(parent.parent.mouseX)) }
        }
    }
    Text {
        anchors.centerIn: parent
        visible: !view.frame
        color: view.theme.foreground
        opacity: .45
        font.family: view.theme.font
        font.pixelSize: view.theme.baseSize
        text: "press play to see the spectrum"
    }
}
