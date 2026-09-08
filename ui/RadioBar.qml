import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Bar widget: the antenna mark, lit while receiving, opening the tuner
// popover. EXPAND summons the panel-kind window through the shell.
BarWidget {
    id: root
    moduleName: "com.omasdr.radio"
    property var session: Session
    property bool opened: false
    property bool popoutSwitchClosing: false
    readonly property var state: session.engine.state
    readonly property bool live: !!state && state.playing
    readonly property bool trouble: !state || state.device.status === "missing" || !!state.error
    function open() { popoutSwitchClosing = false; opened = true; }
    function close() { opened = false; }
    function closeForPopoutSwitch() { popoutSwitchClosing = true; close(); }
    function expand() {
        Quickshell.execDetached(["omarchy", "shell", "shell", session.windowOpen ? "summon" : "toggle", "com.omasdr.radio", "{}"]);
        close();
    }
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    // Follow theme switches: the shell's Color singleton is the source of
    // truth inside the shell; re-read our TOML snapshot when it changes.
    Connections {
        target: Color
        function onForegroundChanged() { root.session.theme.reload(); }
        function onBackgroundChanged() { root.session.theme.reload(); }
        function onAccentChanged() { root.session.theme.reload(); }
    }
    Component.onCompleted: session.theme.reload()
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        slotSize: 27
        opticalSize: 16
        useActiveColor: false
        active: root.opened
        iconComponent: Component {
            Item {
                AntennaMark { anchors.centerIn: parent; ink: button.foreground; live: root.live; opacity: root.state ? 1 : .6 }
                Rectangle { anchors.right: parent.right; anchors.bottom: parent.bottom; width: 5; height: 5; radius: 2.5; color: Color.urgent; visible: root.trouble && !!root.state }
            }
        }
        onPressed: b => {
            if (b === Qt.LeftButton) { if (root.opened) root.close(); else root.open(); }
            else if (b === Qt.MiddleButton) {
                if (root.state) root.session.engine.send({type: root.state.playing ? "stop" : "play"});
                else root.open();
            }
        }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => { if (root.state) root.session.engine.send({type: "step", delta: event.angleDelta.y > 0 ? 1 : -1}); }
        }
    }
    KeyboardPanel {
        id: popup
        anchorItem: button
        bar: root.bar
        owner: root
        open: root.opened
        padding: 12
        borderSpec: Border.flat(Color.accent, 2)
        contentWidth: 344
        contentHeight: content.item ? content.item.implicitHeight + 24 : 360
        focusTarget: content.item
        Loader {
            id: content
            anchors.fill: parent
            active: root.opened
            sourceComponent: Popover {
                session: root.session
                compact: true
                onCloseRequested: root.close()
                onExpandRequested: root.expand()
            }
        }
    }
}
