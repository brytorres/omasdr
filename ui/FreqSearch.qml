import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "Freq.js" as Freq

// What is worth hearing from where the user is: the local airport's tower and
// ATIS, and the analogue repeaters around them. The daemon owns the data and
// the downloads (docs/protocol.md, "Nearby search"); this window only asks,
// shows, and turns an answer into presets.
//
// Results are presets in waiting. Every row carries what save_preset wants, so
// a click tunes it and the star keeps it, and "add all" fills an empty preset
// list with the frequencies of wherever the user actually lives.
Scope {
    id: find
    property var session: Session
    property var theme: session.theme.snapshot
    readonly property var engine: session.engine
    readonly property var state: engine.state
    readonly property string status: engine.nearbyStatus
    readonly property bool busy: status === "searching"
    // The daemon remembers the location, so a reopened window can search again
    // without geocoding and without asking twice.
    readonly property var saved: state && state.location && state.location.name ? state.location : null

    // The window can open before the daemon has connected, so the stored
    // location often arrives after the window does. Prime on whichever
    // happens last rather than only on opening.
    function prime() {
        if (!saved || !win.visible) return;
        if (placeField.text === "") placeField.text = saved.name;
        if (engine.nearbyResults.length === 0 && status !== "searching") run("");
    }
    onSavedChanged: prime()

    function run(place) {
        var text = (place === undefined ? "" : place).trim();
        if (text !== "") engine.searchNearby({place: text});
        else if (saved) engine.searchNearby({});
    }
    // The daemon picks the nearest N of each kind; the list reads better in
    // frequency order, the way the presets and the band itself do.
    function results(kind) {
        return engine.nearbyResults
            .filter(function (r) { return r.kind === kind; })
            .sort(function (a, b) { return a.frequency - b.frequency; });
    }
    function tune(row) {
        if (find.state && row.demod !== find.state.demod) engine.send({type: "set_demod", demod: row.demod});
        engine.send({type: "set_frequency", frequency: row.frequency});
    }
    function keep(row) {
        engine.send({type: "save_preset", name: row.name, frequency: row.frequency,
                     demod: row.demod, tags: row.tags || []});
    }
    function keepAll(kind) {
        for (var row of results(kind)) keep(row);
    }

    FloatingWindow {
        id: win
        title: "OmaSDR · Frequency Search"
        visible: find.session.searchOpen
        onVisibleChanged: {
            if (!visible && find.session.searchOpen) find.session.searchOpen = false;
            else if (visible) {
                placeField.forceActiveFocus();
                // A location already stored means the answer is a click away;
                // don't make them ask for what the daemon already knows.
                find.prime();
            }
        }
        implicitWidth: 720
        implicitHeight: 780
        minimumSize: Qt.size(460, 360)
        color: find.theme.background

        component Label: Text {
            color: find.theme.foreground
            font.family: find.theme.font
            font.pixelSize: find.theme.baseSize
            elide: Text.ElideRight
        }
        component Caption: Label { font.pixelSize: find.theme.baseSize - 2; opacity: .55 }
        component Control: Button {
            id: button
            property bool selected: false
            /// Hover explanation, for the buttons whose label cannot carry it.
            property string tip: ""
            implicitHeight: 26
            implicitWidth: Math.max(26, contentItem.implicitWidth + 14)
            padding: 4
            contentItem: Label {
                text: button.text
                color: button.selected ? find.theme.background : find.theme.foreground
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                opacity: button.enabled ? .9 : .35
            }
            background: Rectangle {
                color: button.selected ? find.theme.accent
                    : button.hovered && button.enabled ? Qt.alpha(find.theme.accent, .16) : "transparent"
                border.width: 1
                border.color: button.activeFocus ? find.theme.accent : Qt.alpha(find.theme.foreground, .22)
            }
            // Hover through a HoverHandler rather than Button.hovered: the
            // latter follows a style hint that is not guaranteed to be on.
            HoverHandler { id: hoverWatch }
            // Hangs below the button, right-aligned so a button at the window
            // edge keeps its tooltip on screen.
            Rectangle {
                visible: hoverWatch.hovered && button.tip !== ""
                z: 100
                anchors.top: parent.bottom
                anchors.topMargin: 4
                anchors.right: parent.right
                implicitWidth: tipText.implicitWidth + 14
                implicitHeight: tipText.implicitHeight + 10
                width: implicitWidth
                height: implicitHeight
                color: find.theme.background
                border.width: 1
                border.color: Qt.alpha(find.theme.accent, .7)
                Label {
                    id: tipText
                    anchors.centerIn: parent
                    font.pixelSize: find.theme.baseSize - 1
                    text: button.tip
                }
            }
        }

        Shortcut { sequence: "Escape"; onActivated: find.session.searchOpen = false }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: false
                spacing: 8
                // Above the rest of the column: the tooltips hang out of this
                // row into the results box below, and that box has a
                // half-transparent background painted after this row, which
                // otherwise washes them out.
                z: 10
                Label { text: "FREQ SEARCH"; font.bold: true; font.letterSpacing: 1 }
                TextField {
                    id: placeField
                    Layout.fillWidth: true
                    implicitHeight: 26
                    placeholderText: "town, postcode, grid square, or 28.08 -80.61"
                    placeholderTextColor: Qt.alpha(find.theme.foreground, .35)
                    font.family: find.theme.font
                    font.pixelSize: find.theme.baseSize
                    color: find.theme.foreground
                    selectionColor: find.theme.accent
                    selectedTextColor: find.theme.background
                    enabled: !find.busy
                    onAccepted: find.run(text)
                    background: Rectangle {
                        color: Qt.alpha(find.theme.background, .5)
                        border.width: 1
                        border.color: placeField.activeFocus ? find.theme.accent : Qt.alpha(find.theme.foreground, .22)
                    }
                }
                Control {
                    text: find.busy ? "…" : "SEARCH"
                    tip: "Find airband and repeaters near this place"
                    selected: !find.busy && placeField.text !== ""
                    enabled: !find.busy && (placeField.text !== "" || !!find.saved)
                    onClicked: find.run(placeField.text)
                }
                Control {
                    text: "RELOAD"
                    tip: "Download the airband and repeater data again,\nrather than using the cached copy"
                    Accessible.name: "Download the data again"
                    enabled: !find.busy && (!!find.saved || placeField.text !== "")
                    onClicked: find.engine.searchNearby(placeField.text !== ""
                        ? {place: placeField.text, refresh: true} : {refresh: true})
                }
            }

            // Where the answer is for, and anything that went sideways.
            Label {
                Layout.fillWidth: true
                visible: text !== ""
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                font.pixelSize: find.theme.baseSize - 1
                color: find.status === "error" ? find.theme.red : find.theme.accent
                text: {
                    if (find.status === "error") return find.engine.nearbyError;
                    if (find.busy) return "searching — the first one downloads the data, so give it a moment";
                    var parts = [];
                    if (find.engine.nearbyLocation) parts.push("from " + find.engine.nearbyLocation.name);
                    for (var n of find.engine.nearbyNotes) parts.push(n);
                    return parts.join(" · ");
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Qt.alpha(find.theme.background, .5)
                border.width: 1
                border.color: Qt.alpha(find.theme.foreground, .17)
                clip: true

                Flickable {
                    id: flick
                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true
                    contentWidth: width
                    contentHeight: body.height + 20
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    ColumnLayout {
                        id: body
                        x: 10
                        y: 10
                        width: flick.width - 30
                        height: implicitHeight
                        spacing: 14

                        Repeater {
                            model: [{kind: "airband", title: "AIRBAND", demod: "AM"},
                                    {kind: "repeater", title: "REPEATERS", demod: "NFM"}]
                            delegate: ColumnLayout {
                                id: section
                                required property var modelData
                                readonly property var rows: find.results(modelData.kind)
                                Layout.fillWidth: true
                                visible: rows.length > 0
                                spacing: 4

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Label {
                                        text: section.modelData.title
                                        font.bold: true
                                        font.letterSpacing: 1
                                        color: find.theme.accent
                                        font.pixelSize: find.theme.baseSize
                                    }
                                    Caption { text: section.rows.length + " · " + section.modelData.demod }
                                    Item { Layout.fillWidth: true }
                                    Control {
                                        text: "★ add all"
                                        implicitHeight: 22
                                        enabled: !!find.state
                                        onClicked: find.keepAll(section.modelData.kind)
                                    }
                                }

                                Repeater {
                                    model: section.rows
                                    delegate: Rectangle {
                                        id: row
                                        required property var modelData
                                        readonly property bool current: find.state && modelData.frequency === find.state.frequency
                                        Layout.fillWidth: true
                                        implicitHeight: 30
                                        color: current ? Qt.alpha(find.theme.accent, .22)
                                            : rowMouse.containsMouse ? Qt.alpha(find.theme.accent, .1) : "transparent"
                                        MouseArea {
                                            id: rowMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: find.tune(row.modelData)
                                        }
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 6
                                            spacing: 8
                                            // Fixed lanes, like the preset rows: the numbers have
                                            // to line up down the list or the list is unreadable.
                                            Label {
                                                Layout.preferredWidth: 132
                                                text: row.modelData.name
                                            }
                                            Label {
                                                Layout.preferredWidth: 74
                                                horizontalAlignment: Text.AlignRight
                                                text: Freq.label(row.modelData.frequency).split(" ")[0]
                                                opacity: .85
                                            }
                                            Label {
                                                Layout.preferredWidth: 26
                                                text: Freq.label(row.modelData.frequency).split(" ")[1]
                                                opacity: .5
                                                font.pixelSize: find.theme.baseSize - 2
                                            }
                                            Label {
                                                Layout.preferredWidth: 52
                                                horizontalAlignment: Text.AlignRight
                                                opacity: .55
                                                font.pixelSize: find.theme.baseSize - 2
                                                text: row.modelData.distance_km < 10
                                                    ? row.modelData.distance_km.toFixed(1) + " km"
                                                    : Math.round(row.modelData.distance_km) + " km"
                                            }
                                            Label {
                                                Layout.fillWidth: true
                                                opacity: .55
                                                font.pixelSize: find.theme.baseSize - 2
                                                text: row.modelData.detail
                                            }
                                            Control {
                                                text: "★"
                                                Accessible.name: "Save as a preset"
                                                implicitHeight: 20
                                                implicitWidth: 22
                                                opacity: rowMouse.containsMouse || hovered ? 1 : .35
                                                enabled: !!find.state
                                                onClicked: find.keep(row.modelData)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Nothing yet, or nothing found.
                        Label {
                            Layout.fillWidth: true
                            Layout.topMargin: 30
                            visible: find.engine.nearbyResults.length === 0 && !find.busy
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            elide: Text.ElideNone
                            opacity: .5
                            text: find.status === "ok"
                                ? "nothing within range — try a larger town, or somewhere nearby"
                                : "type where you are: a town, a postcode, a Maidenhead grid square\nlike IO91wm, or a coordinate pair. It is only used to sort by distance."
                        }
                    }
                }
            }

            // Crediting both sources is the condition this ships under
            // (AGENTS.md, "Nearby search").
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: false
                spacing: 2
                Caption {
                    Layout.fillWidth: true
                    visible: find.engine.nearbyHint !== ""
                    text: find.engine.nearbyHint
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Caption {
                        Layout.fillWidth: true
                        text: {
                            var parts = [];
                            for (var s of find.engine.nearbySources)
                                parts.push(s.name + (s.note ? " (" + s.note + ")" : ""));
                            return parts.length ? "data from " + parts.join(" and ")
                                : "airband from OurAirports · repeaters from hearham.com";
                        }
                    }
                    Control { text: "close"; implicitHeight: 22; onClicked: find.session.searchOpen = false }
                }
            }
        }
    }
}
