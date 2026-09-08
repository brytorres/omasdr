import QtQuick
import Quickshell
import Quickshell.Io

// Connection to the daemon's spectrum socket (docs/protocol.md, FFT
// socket). Only `active` surfaces hold one; frames arrive as byte values
// in a JSON array and are unpacked into a plain array of dB values.
QtObject {
    id: stream
    required property var engine
    property bool active: false
    property int n: 1024
    property real dbMin: -128
    property real dbStep: 0.5
    /// The newest frame: {center, rate, freq, bw, bins: [dB...]} or null.
    property var frame: null
    signal frameReady()
    function receive(data) {
        try {
            var m = JSON.parse(data);
            if (m.v !== 1) return;
            if (m.type === "fft_hello") { n = m.n; dbMin = m.db_min; dbStep = m.db_step; return; }
            if (m.type !== "fft") return;
            var raw = m.bins, bins = new Array(raw.length);
            for (var i = 0; i < raw.length; i++) bins[i] = raw[i] * dbStep + dbMin;
            frame = {center: m.center, rate: m.rate, freq: m.freq, bw: m.bw, bins: bins};
            frameReady();
        } catch (e) { /* a torn line during reconnect; the next frame replaces it */ }
    }
    property var socket: null
    property Component socketFactory: Component {
        Socket {
            path: stream.engine.runtime + "fft.sock"
            connected: true
            parser: SplitParser { onRead: data => stream.receive(data) }
        }
    }
    function connect() {
        if (socket) { var old = socket; socket = null; old.destroy(); }
        socket = socketFactory.createObject(stream);
    }
    onActiveChanged: {
        if (active) connect();
        else if (socket) { var old = socket; socket = null; old.destroy(); frame = null; }
    }
    property Timer reconnect: Timer {
        interval: 1500
        repeat: true
        running: stream.active && (!stream.socket || !stream.socket.connected)
        onTriggered: stream.connect()
    }
}
