import QtQuick
import Quickshell
import Quickshell.Io
import "Toml.js" as Toml

// Colors and font from the active Omarchy theme, watched so a theme switch
// restyles open surfaces. Pattern borrowed from omastorm (MIT).
QtObject {
    id: root
    readonly property string themePath: Quickshell.env("OMASDR_THEME_DIR") || (Quickshell.env("HOME") + "/.local/state/omarchy/current/theme")
    property var colors: ({})
    property var shell: ({})
    function color(value, fallback) {
        var resolved = colors[value] !== undefined ? colors[value] : value;
        return typeof resolved === "string" && /^#[0-9a-fA-F]{6}$/.test(resolved) ? resolved : fallback;
    }
    function setting(key, fallback) { return shell[key] !== undefined ? shell[key] : fallback; }
    // Omarchy rewrites current/theme/ on a theme switch and tells its shell
    // over IPC; the file watch alone is not reliable across that rewrite, so
    // the bar widget and panel call this whenever the shell's palette moves.
    function reload() { colorsFile.reload(); shellFile.reload(); }
    readonly property var snapshot: ({
        background: color(setting("popups.background", colors.background), "#1a1b26"),
        foreground: color(setting("popups.text", colors.foreground), "#a9b1d6"),
        accent: color(colors.accent, "#7aa2f7"),
        yellow: color(colors.yellow, "#e0af68"),
        red: color(colors.red, "#f7768e"),
        green: color(colors.green, "#9ece6a"),
        font: "monospace",
        baseSize: Number(setting("font.base-size", 12)) > 0 ? Number(setting("font.base-size", 12)) : 12
    })
    property FileView colorsFile: FileView {
        path: root.themePath + "/colors.toml"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.colors = Toml.parse(text())
        onLoadFailed: root.colors = ({})
    }
    property FileView shellFile: FileView {
        path: root.themePath + "/shell.toml"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.shell = Toml.parse(text())
        onLoadFailed: root.shell = ({})
    }
}
