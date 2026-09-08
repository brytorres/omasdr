pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Plugin-wide state: the one daemon connection, the theme, and the UI
// preferences the shell would otherwise lose on every plugin reload.
QtObject {
    id: session
    property Engine engine: Engine { eager: session.wanted }
    property Theme theme: Theme {}
    property bool windowOpen: false
    // The frequency reference window. Either surface can open it and there is
    // only ever one, so it hangs off the singleton rather than off whichever
    // card happened to ask for it. Loaded on first use, then kept.
    property bool helpOpen: false
    function toggleHelp() { helpOpen = !helpOpen; }
    property LazyLoader help: LazyLoader {
        loading: session.helpOpen
        // No session: assignment here — inside this component `session` would
        // resolve to FreqHelp's own property, not this singleton. It defaults
        // to the Session singleton anyway.
        FreqHelp { }
    }
    // Surfaces that need a live daemon (an open popover or window) count
    // themselves here; only then is a missing daemon restarted. The bar icon
    // alone must not keep it alive (AGENTS.md: on demand).
    property int wanters: 0
    readonly property bool wanted: wanters > 0 || windowOpen
    property string startupError: ""
    /// This checkout's version, from manifest.json, so a surface can notice
    /// that a plugin update left an older daemon running.
    property string pluginVersion: ""
    // "MHz" or "kHz" for the frequency field. Persisted in ui.json.
    property string unit: "MHz"
    readonly property string root: Quickshell.env("OMASDR_ROOT") || (Quickshell.env("HOME") + "/.config/omarchy/plugins/com.omasdr.radio")
    readonly property string daemon: root + "/daemon/omasdrd.py"
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omasdr"
    readonly property string bootstrapLog: engine.runtime + "daemon.log"

    // The daemon is on demand (AGENTS.md): every surface that needs it calls
    // ensure(), which is a no-op while it runs. System Python on purpose;
    // GNU Radio's bindings live there and nowhere else.
    function ensure() {
        Quickshell.execDetached(["env", "-C", Quickshell.env("HOME"), "/usr/bin/python3", daemon, "ensure"]);
    }
    function stopDaemon() {
        Quickshell.execDetached(["/usr/bin/python3", daemon, "stop"]);
    }
    function setUnit(next) {
        if (next !== "MHz" && next !== "kHz") return;
        unit = next;
        pendingUi = JSON.stringify({unit: unit}) + "\n";
        mkdir.running = true;
    }
    property string pendingUi: ""
    property Process mkdir: Process {
        command: ["mkdir", "-p", session.configDir]
        onExited: uiFile.setText(session.pendingUi)
    }
    property FileView manifestFile: FileView {
        path: session.root + "/manifest.json"
        printErrors: false
        onLoaded: {
            try { session.pluginVersion = String(JSON.parse(text()).version || ""); } catch (e) { session.pluginVersion = ""; }
        }
    }
    property FileView uiFile: FileView {
        path: session.configDir + "/ui.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try { var u = JSON.parse(text()); if (u.unit === "kHz" || u.unit === "MHz") session.unit = u.unit; } catch (e) {}
        }
    }
    property Timer bootstrapRetry: Timer { interval: 15000; repeat: true; running: session.wanted && !session.engine.state; onTriggered: session.ensure() }
    onWantedChanged: if (wanted && !engine.state) ensure()
    property FileView logFile: FileView {
        path: session.bootstrapLog
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            var lines = text().trim().split("\n");
            session.startupError = session.engine.state ? "" : lines[lines.length - 1];
        }
    }
    property Connections engineEvents: Connections {
        target: session.engine
        function onStateChanged() { if (session.engine.state) session.startupError = ""; }
    }
    // No ensure() on load: the daemon starts when a surface opens or play is
    // pressed. A daemon left running by "keep running" is simply connected to.
}
