import QtQuick
import qs.Commons

// The `panel` kind entry point. The shell injects `shell` and `manifest`,
// then calls open(payload) / close().
RadioWindow {
    session: Session
    Connections {
        target: Color
        function onForegroundChanged() { Session.theme.reload(); }
        function onBackgroundChanged() { Session.theme.reload(); }
        function onAccentChanged() { Session.theme.reload(); }
    }
    Component.onCompleted: Session.theme.reload()
}
