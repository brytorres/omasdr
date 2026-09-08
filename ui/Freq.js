// Frequency text helpers. Hertz everywhere in code and on the wire; only
// these two functions know about kHz and MHz.
.pragma library

var UNITS = { kHz: 1e3, MHz: 1e6 };

// "101.1" with unit "MHz" -> 101100000. Accepts a trailing unit in the text
// ("101.1 MHz", "162550k") which then overrides `unit`. Returns 0 when the
// text is not a frequency.
function parse(text, unit) {
    var s = String(text || "").trim().replace(/,/g, "").replace(/_/g, "");
    var m = s.match(/^(\d+(?:\.\d+)?)\s*([kKmMgG]?)(?:hz)?$/i);
    if (!m) return 0;
    var scale = UNITS[unit] || 1;
    var suffix = m[2].toLowerCase();
    if (suffix === "k") scale = 1e3;
    else if (suffix === "m") scale = 1e6;
    else if (suffix === "g") scale = 1e9;
    var hz = Math.round(parseFloat(m[1]) * scale);
    return hz > 0 ? hz : 0;
}

// 101100000 with "MHz" -> "101.100"; with "kHz" -> "101100". Trailing zeros
// are kept to the demod's useful precision so the field does not jump.
function format(hz, unit) {
    if (!hz) return "";
    if (unit === "kHz") {
        var k = hz / 1e3;
        return Number.isInteger(k) ? String(k) : k.toFixed(3).replace(/\.?0+$/, "");
    }
    var mhz = hz / 1e6;
    var text = mhz.toFixed(6).replace(/0+$/, "");
    if (text.endsWith(".")) text += "000";
    var decimals = text.split(".")[1] || "";
    while (decimals.length < 3) { text += "0"; decimals += "0"; }
    return text;
}

// Compact label for lists: "101.1 MHz", "162.550 MHz", "7.200 MHz", "1.030 MHz".
function label(hz) {
    if (hz >= 1e6) return (hz / 1e6).toFixed(hz % 1000 === 0 ? 3 : 4).replace(/\.?0+$/, "") + " MHz";
    return (hz / 1e3).toFixed(hz % 1000 === 0 ? 0 : 1) + " kHz";
}

function stepLabel(step) {
    if (step >= 1e6) return (step / 1e6) + " MHz";
    if (step >= 1e3) return (step / 1e3) + " kHz";
    return step + " Hz";
}
