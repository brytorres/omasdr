import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Freq.js" as Freq

// The tuner card: frequency entry with a kHz/MHz toggle and scroll-to-step,
// demod, play/stop, presets. Lives in the bar popover and, unchanged, in
// the left column of the expanded window.
FocusScope {
    id: card
    required property var session
    property var theme: session.theme.snapshot
    property bool compact: true
    // Window mode with room: presets in a column to the right of the controls.
    property bool presetsBeside: false
    property int presetListHeight: compact ? 150 : presetsBeside ? 170 : 110
    readonly property var engine: session.engine
    readonly property var state: engine.state
    readonly property bool playing: state ? state.playing : false
    readonly property bool recording: !!state && !!state.recording
    property int now: Date.now() / 1000
    Timer { interval: 1000; repeat: true; running: card.recording; onTriggered: card.now = Date.now() / 1000 }
    readonly property string recordLabel: {
        if (!recording) return "● REC";
        var secs = Math.max(0, now - Math.floor(state.recording_started));
        var m = Math.floor(secs / 60), sec = secs % 60;
        return "■ " + (m < 10 ? "0" : "") + m + ":" + (sec < 10 ? "0" : "") + sec;
    }
    property string lastRecording: ""
    onRecordingChanged: {
        if (recording) { lastRecording = state.recording; now = Date.now() / 1000; }
        else if (lastRecording) { notice = "saved " + lastRecording.replace(/^.*\//, ""); noticeTimer.restart(); lastRecording = ""; }
    }
    function toggleRecord() { engine.send({type: "record", enabled: !recording}); }
    readonly property string deviceStatus: state ? state.device.status : "offline"
    readonly property string statusText: {
        if (!state) return session.wanted ? "STARTING" : "IDLE";
        if (state.error) return state.error.toUpperCase();
        switch (deviceStatus) {
        case "ours": return "LIVE";
        case "busy": return "HELD BY " + state.device.held_by.toUpperCase();
        case "missing": return "NO DEVICE";
        default: return "READY";
        }
    }
    readonly property color statusColor: !state || deviceStatus === "missing" || (state && state.error) ? theme.red
        : deviceStatus === "busy" ? theme.yellow : deviceStatus === "ours" ? theme.green : theme.foreground
    signal expandRequested()
    signal closeRequested()
    property string notice: ""
    property string hoverText: ""
    property int hoverIndex: -1
    property real hoverY: 0
    // A plugin update leaves the old daemon running the old code until it is
    // stopped, so say so plainly rather than letting the two drift.
    readonly property bool daemonStale: !!state && session.pluginVersion !== "" && state.version !== session.pluginVersion
    implicitWidth: presetsBeside ? 320 + 14 + 260 : 320
    implicitHeight: outer.implicitHeight

    function tune(hz) { if (hz > 0) engine.send({type: "set_frequency", frequency: hz}); }
    function step(delta) { editing = false; engine.send({type: "step", delta: delta}); }
    property bool pendingPlay: false
    function togglePlay() {
        if (!state) { pendingPlay = true; session.ensure(); return; }
        engine.send({type: playing ? "stop" : "play"});
    }
    function submit() {
        editing = false;
        var hz = Freq.parse(freqField.text, session.unit);
        if (hz > 0) tune(hz); else freqField.text = Freq.format(state ? state.frequency : 0, session.unit);
    }
    // The field follows the daemon unless the user is part-way through
    // typing. Focus alone is not "typing": the arrow keys and the wheel step
    // while the field holds focus, and the text has to follow those.
    property bool editing: false
    function syncField() {
        if (!editing && state) freqField.text = Freq.format(state.frequency, session.unit);
    }
    onStateChanged: {
        syncField();
        if (state && pendingPlay) { pendingPlay = false; if (!state.playing) engine.send({type: "play"}); }
    }
    Connections { target: card.session; function onUnitChanged() { card.editing = false; card.syncField(); } }
    Component.onCompleted: { syncField(); session.wanters++; }
    Component.onDestruction: session.wanters--

    Keys.onEscapePressed: closeRequested()
    Keys.onSpacePressed: event => { if (!freqField.activeFocus) { togglePlay(); event.accepted = true; } }

    component Label: Text {
        color: card.theme.foreground
        font.family: card.theme.font
        font.pixelSize: card.theme.baseSize
        elide: Text.ElideRight
    }
    component Control: Button {
        id: button
        property bool selected: false
        implicitHeight: 28
        implicitWidth: Math.max(28, contentItem.implicitWidth + 14)
        padding: 5
        contentItem: Label {
            text: button.text
            color: button.selected ? card.theme.background : card.theme.foreground
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            opacity: button.enabled ? 1 : .35
        }
        background: Rectangle {
            color: button.selected ? card.theme.accent : button.hovered || button.activeFocus ? Qt.alpha(card.theme.accent, .16) : "transparent"
            border.width: 1
            border.color: button.selected || button.activeFocus ? card.theme.accent : Qt.alpha(card.theme.foreground, .22)
        }
    }

    RowLayout {
        id: outer
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 14
    ColumnLayout {
        id: layout
        Layout.fillWidth: true
        // With the presets beside it this column stays at its natural 320 so
        // any extra width reaches the preset list, which is the part that
        // benefits from it. On its own it fills as before.
        Layout.maximumWidth: card.presetsBeside ? 320 : Number.POSITIVE_INFINITY
        Layout.alignment: Qt.AlignTop
        spacing: 10

        // Header: name, device, status.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Label { text: "OmaSDR"; font.bold: true; font.pixelSize: card.theme.baseSize + 2 }
            Label { Layout.fillWidth: true; opacity: .65; text: card.state && card.state.device.name ? card.state.device.name : "" }
            Rectangle { width: 6; height: 6; radius: 3; color: card.statusColor }
            Label { text: card.statusText; color: card.statusColor; font.pixelSize: card.theme.baseSize - 1 }
        }

        // After a plugin update the running daemon is still the old build.
        Rectangle {
            Layout.fillWidth: true
            visible: card.daemonStale
            implicitHeight: Math.max(28, staleLabel.implicitHeight + 10)
            color: Qt.alpha(card.theme.yellow, .12)
            border.width: 1
            border.color: Qt.alpha(card.theme.yellow, .5)
            Control {
                id: staleButton
                text: "restart"
                implicitHeight: 22
                anchors.right: parent.right
                anchors.rightMargin: 5
                anchors.verticalCenter: parent.verticalCenter
                onClicked: card.session.stopDaemon()
            }
            Label {
                id: staleLabel
                anchors.left: parent.left
                anchors.leftMargin: 7
                anchors.right: staleButton.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                color: card.theme.yellow
                font.pixelSize: card.theme.baseSize - 1
                text: "Plugin is " + card.session.pluginVersion + ", daemon is " + (card.state ? card.state.version : "") + "."
            }
        }

        // Frequency: field, unit toggle, step hint. Wheel and arrows step.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            TextField {
                id: freqField
                Layout.fillWidth: true
                focus: true
                font.family: card.theme.font
                font.pixelSize: card.theme.baseSize + 8
                color: card.theme.foreground
                selectionColor: card.theme.accent
                selectedTextColor: card.theme.background
                placeholderText: card.session.unit === "MHz" ? "101.100" : "101100"
                placeholderTextColor: Qt.alpha(card.theme.foreground, .35)
                horizontalAlignment: TextInput.AlignRight
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                validator: RegularExpressionValidator { regularExpression: /[0-9.,]*\s*[kKmMgG]?/ }
                background: Rectangle {
                    color: Qt.alpha(card.theme.background, .5)
                    border.width: 1
                    border.color: freqField.activeFocus ? card.theme.accent : Qt.alpha(card.theme.foreground, .22)
                }
                onAccepted: { card.submit(); freqField.selectAll(); }
                onTextEdited: card.editing = true
                onActiveFocusChanged: if (!activeFocus) { card.editing = false; card.syncField(); }
                Keys.onUpPressed: card.step(1)
                Keys.onDownPressed: card.step(-1)
                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => card.step(event.angleDelta.y > 0 ? 1 : -1)
                }
                MouseArea { anchors.fill: parent; acceptedButtons: Qt.NoButton; cursorShape: Qt.IBeamCursor }
            }
            Control {
                text: card.session.unit
                Accessible.name: "Toggle kHz and MHz"
                implicitWidth: 48
                // Same height and the same top and bottom edge as the field
                // beside it. The field is taller than a normal control
                // because of its larger type, so take the height from it
                // rather than leaving the button at its own 28.
                Layout.preferredHeight: freqField.implicitHeight
                Layout.alignment: Qt.AlignVCenter
                onClicked: card.session.setUnit(card.session.unit === "MHz" ? "kHz" : "MHz")
            }
        }

        // Signal level in the tuned channel while playing.
        Item {
            Layout.fillWidth: true
            implicitHeight: 6
            visible: card.playing
            Rectangle { anchors.fill: parent; color: Qt.alpha(card.theme.foreground, .12) }
            Rectangle {
                readonly property real fill: Math.max(0, Math.min(1, (card.engine.level + 100) / 80))
                width: parent.width * fill
                height: parent.height
                color: fill > .85 ? card.theme.red : card.theme.accent
                Behavior on width { NumberAnimation { duration: 120 } }
            }
            Label {
                anchors.right: parent.right; anchors.bottom: parent.top; anchors.bottomMargin: 1
                font.pixelSize: card.theme.baseSize - 3; opacity: .55
                text: card.engine.level > -150 ? card.engine.level.toFixed(0) + " dB" : ""
            }
        }

        // Demod, step, transport.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            ComboBox {
                id: demodBox
                Layout.preferredWidth: 104
                implicitHeight: 28
                model: card.engine.demods
                textRole: "label"
                valueRole: "id"
                currentIndex: card.state ? card.engine.demods.findIndex(d => d.id === card.state.demod) : -1
                onActivated: index => card.engine.send({type: "set_demod", demod: card.engine.demods[index].id})
                font.family: card.theme.font
                font.pixelSize: card.theme.baseSize
                contentItem: Label { text: demodBox.displayText; verticalAlignment: Text.AlignVCenter; leftPadding: 8 }
                background: Rectangle {
                    color: demodBox.hovered || demodBox.activeFocus ? Qt.alpha(card.theme.accent, .16) : "transparent"
                    border.width: 1
                    border.color: demodBox.activeFocus ? card.theme.accent : Qt.alpha(card.theme.foreground, .22)
                }
                popup: Popup {
                    y: demodBox.height
                    width: demodBox.width
                    padding: 1
                    background: Rectangle { color: card.theme.background; border.width: 1; border.color: card.theme.accent }
                    contentItem: ListView {
                        implicitHeight: contentHeight
                        model: demodBox.popup.visible ? demodBox.delegateModel : null
                        currentIndex: demodBox.highlightedIndex
                    }
                }
                delegate: ItemDelegate {
                    required property var model
                    required property int index
                    width: demodBox.width
                    height: 26
                    highlighted: demodBox.highlightedIndex === index
                    contentItem: Label { text: model.label; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: highlighted ? Qt.alpha(card.theme.accent, .25) : "transparent" }
                }
            }
            Label { Layout.fillWidth: true; opacity: .55; font.pixelSize: card.theme.baseSize - 2; text: card.state ? "step " + Freq.stepLabel(card.state.step) : "" }
            Control {
                text: card.recordLabel
                Accessible.name: "Record audio"
                enabled: card.playing
                selected: card.recording
                onClicked: card.toggleRecord()
                contentItem: Label {
                    text: parent.text
                    color: card.recording ? card.theme.background : card.theme.red
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    opacity: parent.enabled ? 1 : .35
                }
                background: Rectangle {
                    color: card.recording ? card.theme.red : parent.hovered ? Qt.alpha(card.theme.red, .16) : "transparent"
                    border.width: 1
                    border.color: card.recording ? card.theme.red : Qt.alpha(card.theme.foreground, .22)
                }
            }
            Control {
                text: card.pendingPlay ? "…" : card.playing ? "■ STOP" : "▶ PLAY"
                selected: card.playing
                enabled: !card.state || card.deviceStatus !== "missing"
                onClicked: card.togglePlay()
            }
        }

        // Presets, unless they live beside the controls.
        Loader { Layout.fillWidth: true; active: !card.presetsBeside; visible: active; sourceComponent: presetsBlock }

        // Notices.
        Label {
            Layout.fillWidth: true
            visible: text !== ""
            wrapMode: Text.Wrap
            color: card.theme.accent
            text: card.engine.rejection || (!card.state ? (card.session.startupError || card.engine.error) : "") || card.notice
        }
        Connections {
            target: card.engine
            function onImported(added, skipped) {
                card.notice = "gqrx import: " + added + " added, " + skipped + " already present";
                noticeTimer.restart();
            }
        }
        Timer { id: noticeTimer; interval: 6000; onTriggered: card.notice = "" }

    }

    // Grows into whatever the window gives the card. Preset rows are fixed
    // lanes with the name taking the slack, so more width is more name. The
    // cap is high enough that a maximised window on a normal display has no
    // slack left over — a lower one left a dead gap between the list and the
    // receiver column — and low enough that an ultrawide does not get a
    // single absurd line.
    Loader {
        Layout.fillWidth: true
        Layout.minimumWidth: 260
        Layout.maximumWidth: 720
        Layout.alignment: Qt.AlignTop
        active: card.presetsBeside
        visible: active
        sourceComponent: presetsBlock
    }
    }

    Component {
        id: presetsBlock
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                Label { text: "PRESETS"; font.pixelSize: card.theme.baseSize - 2; opacity: .55; font.letterSpacing: 1 }
                Item { Layout.fillWidth: true }
                Control { text: "★ save"; implicitHeight: 22; enabled: !!card.state; onClicked: nameDialog.open() }
                Control { text: "⇣ gqrx"; implicitHeight: 22; enabled: !!card.state; onClicked: card.engine.send({type: "import_gqrx"}) }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: card.presetsBeside ? card.presetListHeight : Math.min(card.presetListHeight, Math.max(28, presetList.contentHeight))
                color: Qt.alpha(card.theme.background, .5)
                border.width: 1
                border.color: Qt.alpha(card.theme.foreground, .17)
                ListView {
                    id: presetList
                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true
                    model: card.engine.presets
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        readonly property bool current: card.state && modelData.frequency === card.state.frequency
                        width: presetList.width
                        height: 26
                        color: current ? Qt.alpha(card.theme.accent, .22) : rowMouse.containsMouse ? Qt.alpha(card.theme.accent, .1) : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 6
                            spacing: 8
                            // Fixed columns so the numbers line up down the
                            // list: the value right-aligned, the unit and the
                            // mode each in their own lane.
                            Label { Layout.fillWidth: true; text: modelData.name }
                            Label {
                                Layout.preferredWidth: 58
                                horizontalAlignment: Text.AlignRight
                                text: Freq.label(modelData.frequency).split(" ")[0]
                                opacity: .85
                            }
                            Label {
                                Layout.preferredWidth: 26
                                text: Freq.label(modelData.frequency).split(" ")[1]
                                opacity: .5
                                font.pixelSize: card.theme.baseSize - 2
                            }
                            Label {
                                Layout.preferredWidth: 62
                                text: (card.engine.demod(modelData.demod) || {label: modelData.demod}).label
                                opacity: .5
                                font.pixelSize: card.theme.baseSize - 2
                            }
                            Label {
                                text: "×"; opacity: rowMouse.containsMouse ? .7 : 0
                                MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: card.engine.send({type: "delete_preset", frequency: modelData.frequency}) }
                            }
                        }
                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            z: -1
                            onContainsMouseChanged: {
                                if (!containsMouse) { if (card.hoverIndex === index) card.hoverIndex = -1; return; }
                                var demodLabel = (card.engine.demod(modelData.demod) || {label: modelData.demod}).label;
                                var parts = [modelData.name, Freq.label(modelData.frequency), demodLabel];
                                if (modelData.tags && modelData.tags.length) parts.push(modelData.tags.join(", "));
                                card.hoverText = parts.join("  |  ");
                                card.hoverIndex = index;
                                card.hoverY = index * height - presetList.contentY;
                            }
                            onClicked: {
                                if (modelData.demod !== card.state.demod) card.engine.send({type: "set_demod", demod: modelData.demod});
                                card.tune(modelData.frequency);
                            }
                        }
                    }
                }
                Label {
                    anchors.centerIn: parent
                    width: parent.width - 16
                    horizontalAlignment: Text.AlignHCenter
                    visible: card.engine.presets.length === 0
                    opacity: .45
                    text: "no presets yet · ★ saves the current one"
                }
                // Hover tooltip: the full name, which the row elides, plus
                // frequency, mode, and tags. Outside the ListView so it is
                // not clipped, and clamped to stay on the card.
                Rectangle {
                    id: presetTip
                    visible: card.hoverIndex >= 0 && card.hoverText !== ""
                    z: 10
                    x: 6
                    y: Math.max(2, Math.min(parent.height - height - 2, card.hoverY + 28))
                    width: Math.min(parent.width - 12, tipText.implicitWidth + 14)
                    height: tipText.implicitHeight + 10
                    color: card.theme.background
                    border.width: 1
                    border.color: Qt.alpha(card.theme.accent, .7)
                    Label {
                        id: tipText
                        anchors.centerIn: parent
                        width: parent.width - 14
                        elide: Text.ElideRight
                        font.pixelSize: card.theme.baseSize - 1
                        text: card.hoverText
                    }
                }
            }
            // The row under the presets: the reference on the left, with room
            // beside it for the "near you" search later, and EXPAND on the
            // right in the popover. The daemon controls are not here; they
            // live in the window's bottom bar.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: 6
                Control {
                    text: "ℹ FREQ HELP"
                    Accessible.name: "Open the frequency reference"
                    implicitHeight: 22
                    selected: card.session.helpOpen
                    onClicked: card.session.toggleHelp()
                }
                Control {
                    text: "⌕ FREQ SEARCH"
                    Accessible.name: "Find what is on the air near you"
                    implicitHeight: 22
                    selected: card.session.searchOpen
                    onClicked: card.session.toggleSearch()
                }
                Item { Layout.fillWidth: true }
                Control {
                    text: "⤢ EXPAND"
                    implicitHeight: 22
                    visible: card.compact
                    onClicked: card.expandRequested()
                }
            }
        }

    }

    // Name prompt for saving a preset.
    Popup {
        id: nameDialog
        modal: true
        focus: true
        x: (card.width - width) / 2
        y: 40
        width: 260
        padding: 10
        background: Rectangle { color: card.theme.background; border.width: 1; border.color: card.theme.accent }
        // A preset is keyed by frequency, so saving where one exists replaces
        // it. Say so, prefill its name, and label the button "replace".
        readonly property var existing: card.state ? card.engine.presets.find(p => p.frequency === card.state.frequency) || null : null
        onOpened: {
            nameField.text = existing ? existing.name : card.state ? Freq.label(card.state.frequency) : "";
            nameField.selectAll();
            nameField.forceActiveFocus();
        }
        function save() {
            card.engine.send({type: "save_preset", name: nameField.text, frequency: card.state.frequency, demod: card.state.demod});
            nameDialog.close();
        }
        ColumnLayout {
            anchors.fill: parent
            spacing: 8
            Label { text: nameDialog.existing ? "Replace preset at " + Freq.label(card.state.frequency) + "?" : "Preset name" }
            Label {
                Layout.fillWidth: true
                visible: !!nameDialog.existing
                wrapMode: Text.Wrap
                color: card.theme.yellow
                font.pixelSize: card.theme.baseSize - 1
                text: nameDialog.existing ? "“" + nameDialog.existing.name + "” is already saved here. Saving replaces it; tune elsewhere to add a new one." : ""
            }
            TextField {
                id: nameField
                Layout.fillWidth: true
                font.family: card.theme.font
                color: card.theme.foreground
                background: Rectangle { color: Qt.alpha(card.theme.background, .5); border.width: 1; border.color: nameField.activeFocus ? card.theme.accent : Qt.alpha(card.theme.foreground, .22) }
                onAccepted: nameDialog.save()
            }
            RowLayout {
                Item { Layout.fillWidth: true }
                Control { text: "cancel"; onClicked: nameDialog.close() }
                Control { text: nameDialog.existing ? "replace" : "save"; selected: true; onClicked: nameDialog.save() }
            }
        }
    }
}
