import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "Freq.js" as Freq

// The expanded window: the tuner card on the left, receiver settings on
// the right, and the space the waterfall and spectrum plot will fill.
Item {
    id: app
    property var session: Session
    property var shell: null
    property var manifest: null
    // A standalone launcher (ui/shell.qml) owns its process; the plugin does not.
    property bool standalone: false
    property bool opened: standalone
    property var theme: session.theme.snapshot
    readonly property var engine: session.engine
    readonly property var state: engine.state
    function open(payload) { opened = true; session.windowOpen = true; }
    function close() { if (!opened) return; opened = false; session.windowOpen = false; }
    function dismiss() {
        if (standalone) Qt.quit();
        else if (shell) shell.hide("com.omasdr.radio");
        else close();
    }
    Component.onCompleted: if (standalone) session.windowOpen = true

    FloatingWindow {
        id: win
        title: "OmaSDR"
        visible: app.opened
        // The window has to hand the tuner keyboard focus itself; the bar
        // popover gets it from KeyboardPanel's focusTarget, but nothing does
        // it here, and without it the frequency field ignores typing and the
        // arrow keys.
        onVisibleChanged: {
            if (!visible && app.opened) app.dismiss();
            else if (visible) tuner.forceActiveFocus();
        }
        implicitWidth: Number(Quickshell.env("OMASDR_WIDTH")) || 1100
        implicitHeight: Number(Quickshell.env("OMASDR_HEIGHT")) || 720
        minimumSize: Qt.size(720, 520)
        color: app.theme.background

        component Label: Text {
            color: app.theme.foreground
            font.family: app.theme.font
            font.pixelSize: app.theme.baseSize
            elide: Text.ElideRight
        }
        component Caption: Label { font.pixelSize: app.theme.baseSize - 2; opacity: .55; font.letterSpacing: 1 }
        component Hint: Label { Layout.fillWidth: true; font.pixelSize: app.theme.baseSize - 2; opacity: .55; elide: Text.ElideRight }
        component Field: TextField {
            id: field
            implicitHeight: 26
            font.family: app.theme.font
            font.pixelSize: app.theme.baseSize
            color: app.theme.foreground
            selectionColor: app.theme.accent
            selectedTextColor: app.theme.background
            background: Rectangle {
                color: Qt.alpha(app.theme.background, .5)
                border.width: 1
                border.color: field.activeFocus ? app.theme.accent : Qt.alpha(app.theme.foreground, .22)
            }
        }
        component Knob: Slider {
            id: slider
            implicitHeight: 22
            handle: Rectangle {
                x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
                y: slider.topPadding + slider.availableHeight / 2 - height / 2
                width: 12; height: 12; radius: 6
                color: slider.pressed ? app.theme.accent : app.theme.foreground
            }
            background: Rectangle {
                x: slider.leftPadding; y: slider.topPadding + slider.availableHeight / 2 - height / 2
                width: slider.availableWidth; height: 3
                color: Qt.alpha(app.theme.foreground, .25)
                Rectangle { width: slider.visualPosition * parent.width; height: parent.height; color: app.theme.accent }
            }
        }

        Shortcut { sequences: ["Escape", "q"]; onActivated: app.dismiss() }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 12

            // Top band: tuner (with presets beside it when there is room) and
            // receiver settings. Everything below is spectrum. Nested layouts
            // fill by default, so say no or the band eats the window.
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: false
                spacing: 16
                Popover {
                    id: tuner
                    focus: true
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: implicitWidth
                    session: app.session
                    compact: false
                    presetsBeside: win.width >= 1040
                    onCloseRequested: app.dismiss()
                }
                Rectangle { Layout.fillHeight: true; width: 1; color: Qt.alpha(app.theme.foreground, .17) }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 8
                    Caption { text: "RECEIVER" }
                    GridLayout {
                        Layout.fillWidth: true
                        columns: win.width >= 1040 ? 2 : 2
                        columnSpacing: 12
                        rowSpacing: 8

                        Label { text: "Gain" }
                        RowLayout {
                            Layout.fillWidth: true
                            ComboBox {
                                id: gainBox
                                Layout.preferredWidth: 110
                                implicitHeight: 26
                                font.family: app.theme.font
                                font.pixelSize: app.theme.baseSize
                                // Before the first playback the tuner's steps are unknown; show
                                // the configured value alone so "auto" is not implied.
                                model: ["auto"].concat(app.state ? (app.state.gain_range.length ? app.state.gain_range.map(g => String(g))
                                    : app.state.gain === "auto" ? [] : [String(app.state.gain)]) : [])
                                currentIndex: app.state ? Math.max(0, model.indexOf(String(app.state.gain))) : 0
                                onActivated: index => app.engine.send({type: "set_gain", gain: index === 0 ? "auto" : Number(model[index])})
                            }
                            Hint { text: app.state && app.state.gain_range.length ? "dB" : "dB · steps known after play" }
                        }

                        Label { text: "Correction" }
                        RowLayout {
                            Layout.fillWidth: true
                            Field {
                                id: ppmField
                                Layout.preferredWidth: 70
                                text: app.state ? String(app.state.ppm) : ""
                                validator: IntValidator { bottom: -500; top: 500 }
                                onEditingFinished: if (app.state && Number(text) !== app.state.ppm) app.engine.send({type: "set_ppm", ppm: Number(text)})
                            }
                            Hint { text: "ppm" }
                        }

                        Label { text: "Sample rate" }
                        RowLayout {
                            Layout.fillWidth: true
                            ComboBox {
                                id: rateBox
                                Layout.preferredWidth: 130
                                implicitHeight: 26
                                font.family: app.theme.font
                                font.pixelSize: app.theme.baseSize
                                model: ["1024000", "1800000", "2048000", "2400000", "2560000"]
                                currentIndex: app.state ? Math.max(0, model.indexOf(String(app.state.sample_rate))) : 3
                                onActivated: index => app.engine.send({type: "set_sample_rate", sample_rate: Number(model[index])})
                            }
                            Hint { text: "S/s · restarts" }
                        }

                        Label { text: "Squelch" }
                        RowLayout {
                            Layout.fillWidth: true
                            Knob {
                                Layout.fillWidth: true
                                from: -150; to: 0; stepSize: 1
                                value: app.state ? app.state.squelch : -150
                                onMoved: app.engine.send({type: "set_squelch", squelch: value})
                            }
                            Caption { Layout.preferredWidth: 52; text: app.state ? (app.state.squelch <= -150 ? "open" : app.state.squelch.toFixed(0) + " dB") : "" }
                        }

                        Label { text: "Volume" }
                        RowLayout {
                            Layout.fillWidth: true
                            Knob {
                                Layout.fillWidth: true
                                from: 0; to: 1; stepSize: 0.02
                                value: app.state ? app.state.volume : 0.5
                                onMoved: app.engine.send({type: "set_volume", volume: value})
                            }
                            Caption { Layout.preferredWidth: 52; text: app.state ? Math.round(app.state.volume * 100) + "%" : "" }
                        }

                        Label { text: "Recordings" }
                        Field {
                            id: recDir
                            Layout.fillWidth: true
                            text: app.state && app.state.record_dir ? app.state.record_dir : ""
                            onEditingFinished: if (app.state && text !== app.state.record_dir) app.engine.send({type: "set_record_dir", record_dir: text})
                        }
                    }
                }
            }

            // Spectrum and waterfall, full width.
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: false
                Caption { text: "SPECTRUM" }
                Item { Layout.fillWidth: true }
                Caption { text: app.state && app.state.playing ? Freq.stepLabel(app.state.step) + " per scroll · click to tune" : "" }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Qt.alpha(app.theme.background, .5)
                border.width: 1
                border.color: Qt.alpha(app.theme.foreground, .17)
                clip: true
                FftStream {
                    id: fft
                    engine: app.engine
                    active: app.opened && !!app.state && app.state.playing
                }
                Spectrum {
                    anchors.fill: parent
                    anchors.margins: 6
                    stream: fft
                    theme: app.theme
                    bandplan: app.engine.bandplan
                    step: app.state ? app.state.step : 100000
                    plotHeight: Math.max(90, Math.round(height * 0.3))
                    onTuneRequested: hz => app.engine.send({type: "set_frequency", frequency: hz})
                    onStepRequested: delta => app.engine.send({type: "step", delta: delta})
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: false
                Caption {
                    Layout.fillWidth: true
                    text: (app.engine.daemonVersion ? "daemon " + app.engine.daemonVersion + " · " : "") + (app.state ? Freq.label(app.state.frequency) + " · " + app.state.demod.toUpperCase() : "offline")
                }
                // The daemon's own controls, together: whether it stays
                // resident and the switch that stops it now.
                CheckBox {
                    id: keep
                    text: "keep daemon running"
                    enabled: !!app.state
                    checked: app.state ? app.state.keep_running : false
                    onToggled: app.engine.send({type: "set_keep_running", enabled: checked})
                    font.family: app.theme.font
                    font.pixelSize: app.theme.baseSize - 1
                    contentItem: Label {
                        text: keep.text
                        leftPadding: keep.indicator.width + 6
                        verticalAlignment: Text.AlignVCenter
                        opacity: keep.enabled ? .8 : .35
                        font.pixelSize: app.theme.baseSize - 1
                    }
                    indicator: Rectangle {
                        implicitWidth: 14; implicitHeight: 14
                        y: parent.height / 2 - height / 2
                        color: keep.checked ? app.theme.accent : "transparent"
                        border.width: 1
                        border.color: keep.checked ? app.theme.accent : Qt.alpha(app.theme.foreground, .4)
                    }
                }
                Button {
                    id: stopButton
                    text: "stop daemon"
                    implicitHeight: 24
                    enabled: !!app.state
                    onClicked: app.session.stopDaemon()
                    contentItem: Label { text: stopButton.text; opacity: stopButton.enabled ? .8 : .35; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: stopButton.hovered ? Qt.alpha(app.theme.accent, .16) : "transparent"; border.width: 1; border.color: Qt.alpha(app.theme.foreground, .22) }
                }
            }
        }
    }
}
