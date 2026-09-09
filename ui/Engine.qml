import QtQuick
import Quickshell
import Quickshell.Io

// One JSON-lines connection to the daemon (docs/protocol.md). `state` is the
// daemon's last state message or null while unreachable; `presets` and
// `demods` come from hello and later presets broadcasts.
QtObject {
    id: engine
    property var state: null
    property var demods: []
    property var presets: []
    property string daemonVersion: ""
    /// gqrx bandplan rows from hello: {start, stop, mode, step, color, name}.
    property var bandplan: []
    /// Signal level in the tuned channel, dB, updated a few times a second while playing.
    property real level: -150
    /// Transport trouble: unreachable, unreadable, wrong protocol version.
    property string error: ""
    /// The daemon's answer to this client's last command when it was refused.
    property string rejection: ""
    property bool incompatible: false
    signal imported(int added, int skipped)
    /// The nearby search (docs/protocol.md): "", "searching", "ok", "error".
    /// It answers twice, so the status is what the window watches, not a reply.
    property string nearbyStatus: ""
    property string nearbyError: ""
    property var nearbyLocation: null
    property var nearbyResults: []
    property var nearbySources: []
    property var nearbyNotes: []
    property string nearbyHint: ""
    function searchNearby(args) {
        nearbyStatus = "searching";
        nearbyError = "";
        send(Object.assign({type: "search_nearby"}, args || {}));
    }
    readonly property string runtime: (Quickshell.env("OMASDR_RUNTIME_DIR") || (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omasdr") + "/"
    readonly property bool connected: socket && socket.connected
    function demod(id) {
        for (var d of demods) if (d.id === id) return d;
        return null;
    }
    function receive(data) {
        if (incompatible) return;
        try {
            var message = JSON.parse(data);
            if (message.v !== 1) {
                incompatible = true;
                state = null;
                error = "Unsupported daemon protocol version: " + message.v;
                socket.connected = false;
                return;
            }
            if (message.type === "hello") {
                demods = message.demods;
                presets = message.presets;
                daemonVersion = message.version;
                bandplan = message.bandplan || [];
            } else if (message.type === "state") {
                state = message;
                error = "";
                if (!message.playing) level = -150;
            } else if (message.type === "presets") presets = message.presets;
            else if (message.type === "level") level = message.db;
            else if (message.type === "nearby") {
                nearbyStatus = message.status;
                if (message.status === "ok") {
                    nearbyLocation = message.location || null;
                    nearbyResults = message.results || [];
                    nearbySources = message.sources || [];
                    nearbyNotes = message.notes || [];
                    nearbyHint = message.hint || "";
                    nearbyError = "";
                } else if (message.status === "error") nearbyError = message.message || "Search failed";
            }
            else if (message.type === "error") {
                rejection = message.message;
                // A refusal arrives instead of the "searching" acknowledgement,
                // so a search waiting on one has to be told it lost.
                if (nearbyStatus === "searching") { nearbyStatus = "error"; nearbyError = message.message; }
            }
            else if (message.type === "imported") imported(message.added, message.skipped);
        } catch (e) { state = null; error = "Invalid daemon message: " + e; }
    }
    function send(command) {
        rejection = "";
        if (!socket || !socket.connected) { error = "Daemon not connected"; return; }
        socket.write(JSON.stringify(command) + "\n");
    }
    property var socket: socketFactory.createObject(engine)
    property Component socketFactory: Component {
        Socket {
            path: engine.runtime + "control.sock"
            connected: true
            parser: SplitParser { onRead: data => engine.receive(data) }
            onConnectedChanged: {
                if (!connected && !engine.incompatible) {
                    engine.state = null;
                    engine.error = "Daemon disconnected. Reconnecting…";
                }
            }
            onError: { if (!engine.incompatible) engine.error = "Daemon unavailable. Starting…"; }
        }
    }
    /// Set by the session: fast reconnects while a surface is open, slow otherwise.
    property bool eager: false
    property Timer reconnect: Timer {
        interval: engine.eager ? 1000 : 10000
        repeat: true
        running: engine.socket && !engine.socket.connected && !engine.incompatible
        // A failed connect leaves the underlying socket allocated; replace it.
        onTriggered: {
            var previous = engine.socket;
            engine.socket = engine.socketFactory.createObject(engine);
            previous.destroy();
        }
    }
}
