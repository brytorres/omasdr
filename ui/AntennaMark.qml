import QtQuick

// The OmaSDR mark: a short whip antenna with two arcs radiating over its
// tip, on a 16 px grid so it sits with the other bar glyphs. `live` fills
// the arcs; idle leaves them faint.
Canvas {
    id: mark
    property color ink: "white"
    property bool live: false
    implicitWidth: 16
    implicitHeight: 16
    onInkChanged: requestPaint()
    onLiveChanged: requestPaint()
    onPaint: {
        var ctx = getContext("2d");
        ctx.reset();
        ctx.strokeStyle = ink;
        ctx.fillStyle = ink;
        ctx.lineCap = "round";
        var cx = 8, cy = 8.5;          // tip of the whip; arcs are centred here
        // Whip and feet.
        ctx.globalAlpha = 1;
        ctx.lineWidth = 1.6;
        ctx.beginPath(); ctx.moveTo(cx, 15); ctx.lineTo(cx, cy); ctx.stroke();
        ctx.beginPath(); ctx.moveTo(cx - 3, 15); ctx.lineTo(cx + 3, 15); ctx.stroke();
        // Tip.
        ctx.beginPath(); ctx.arc(cx, cy, 1.5, 0, Math.PI * 2); ctx.fill();
        // Two arcs over the tip, from lower-left round the top to lower-right,
        // kept inside the canvas (largest radius 6.5 reaches y = 2).
        ctx.lineWidth = 1.3;
        var alphas = live ? [0.95, 0.6] : [0.45, 0.25];
        var radii = [3.5, 6.5];
        for (var i = 0; i < radii.length; i++) {
            ctx.globalAlpha = alphas[i];
            ctx.beginPath();
            ctx.arc(cx, cy, radii[i], Math.PI * 1.08, Math.PI * 1.92);
            ctx.stroke();
        }
    }
}
