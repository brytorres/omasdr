import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "Markdown.js" as Md

// The frequency reference window. It reads docs/frequencies.md at runtime and
// renders it, so the document stays the single editable copy: edit the
// markdown, reopen the window, and the change is there. Only one of these
// exists, held by Session, because either surface can open it.
Scope {
    id: help
    property var session: Session
    property var theme: session.theme.snapshot
    property var blocks: []
    property string query: ""
    readonly property var shown: Md.filter(blocks, query)

    FileView {
        path: help.session.root + "/docs/frequencies.md"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: help.blocks = Md.parse(text())
        onLoadFailed: help.blocks = []
    }

    FloatingWindow {
        id: win
        title: "OmaSDR · Frequency Reference"
        visible: help.session.helpOpen
        // Closing from the window decorations has to reach the flag the
        // binding above reads, or the window can never be reopened.
        onVisibleChanged: {
            if (!visible && help.session.helpOpen) help.session.helpOpen = false;
            else if (visible) search.forceActiveFocus();
        }
        implicitWidth: 760
        implicitHeight: 820
        minimumSize: Qt.size(420, 320)
        color: help.theme.background

        component Label: Text {
            color: help.theme.foreground
            font.family: help.theme.font
            font.pixelSize: help.theme.baseSize
            elide: Text.ElideRight
        }
        component Caption: Label { font.pixelSize: help.theme.baseSize - 2; opacity: .55; font.letterSpacing: 1 }
        component Control: Button {
            id: button
            implicitHeight: 24
            implicitWidth: Math.max(24, contentItem.implicitWidth + 14)
            padding: 4
            contentItem: Label {
                text: button.text
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                opacity: .85
            }
            background: Rectangle {
                color: button.hovered ? Qt.alpha(help.theme.accent, .16) : "transparent"
                border.width: 1
                border.color: button.activeFocus ? help.theme.accent : Qt.alpha(help.theme.foreground, .22)
            }
        }

        Shortcut { sequence: "Escape"; onActivated: help.session.helpOpen = false }
        Shortcut { sequences: ["Ctrl+F", "/"]; onActivated: { search.forceActiveFocus(); search.selectAll(); } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: false
                spacing: 8
                Label { text: "FREQUENCY REFERENCE"; font.bold: true; font.letterSpacing: 1 }
                Item { Layout.fillWidth: true }
                Caption {
                    visible: help.query !== ""
                    text: help.shown.length === 0 ? "no match" : help.shown.length + " blocks"
                }
                TextField {
                    id: search
                    Layout.preferredWidth: 190
                    implicitHeight: 26
                    placeholderText: "search"
                    placeholderTextColor: Qt.alpha(help.theme.foreground, .35)
                    font.family: help.theme.font
                    font.pixelSize: help.theme.baseSize
                    color: help.theme.foreground
                    selectionColor: help.theme.accent
                    selectedTextColor: help.theme.background
                    onTextChanged: help.query = text
                    Keys.onEscapePressed: {
                        if (text !== "") text = "";
                        else help.session.helpOpen = false;
                    }
                    background: Rectangle {
                        color: Qt.alpha(help.theme.background, .5)
                        border.width: 1
                        border.color: search.activeFocus ? help.theme.accent : Qt.alpha(help.theme.foreground, .22)
                    }
                }
                Control {
                    text: "×"
                    visible: help.query !== ""
                    Accessible.name: "Clear the search"
                    onClicked: { search.text = ""; search.forceActiveFocus(); }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Qt.alpha(help.theme.background, .5)
                border.width: 1
                border.color: Qt.alpha(help.theme.foreground, .17)
                clip: true

                Flickable {
                    id: flick
                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true
                    contentWidth: width
                    contentHeight: doc.height + 24
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    ColumnLayout {
                        id: doc
                        x: 14
                        y: 12
                        width: flick.width - 34
                        height: implicitHeight
                        spacing: 0

                        Repeater {
                            model: help.shown
                            delegate: ColumnLayout {
                                id: blk
                                required property var modelData
                                required property int index
                                readonly property string kind: modelData.type
                                readonly property int level: kind === "h" ? modelData.level : 0
                                // The window header is already the title, so
                                // the document's own h1 would be a second one.
                                visible: level !== 1
                                readonly property string body: modelData.text === undefined ? "" : modelData.text
                                Layout.fillWidth: true
                                Layout.topMargin: index === 0 ? 0 : level === 1 ? 0 : level === 2 ? 20 : level ? 13 : 8
                                spacing: 0

                                // Heading, with a rule under the section ones.
                                Label {
                                    visible: blk.level > 0
                                    Layout.fillWidth: true
                                    text: visible ? Md.inline(blk.body, help.theme.yellow, help.theme.accent) : ""
                                    textFormat: Text.StyledText
                                    wrapMode: Text.WordWrap
                                    elide: Text.ElideNone
                                    font.bold: true
                                    font.pixelSize: help.theme.baseSize + (blk.level === 1 ? 7 : blk.level === 2 ? 4 : 1)
                                    color: blk.level <= 2 ? help.theme.accent : help.theme.foreground
                                }
                                Rectangle {
                                    visible: blk.level === 1 || blk.level === 2
                                    Layout.fillWidth: true
                                    Layout.topMargin: 5
                                    implicitHeight: 1
                                    color: Qt.alpha(help.theme.accent, .35)
                                }

                                // Paragraph.
                                Label {
                                    visible: blk.kind === "p"
                                    Layout.fillWidth: true
                                    Layout.topMargin: 6
                                    text: visible ? Md.inline(blk.body, help.theme.yellow, help.theme.accent) : ""
                                    textFormat: Text.StyledText
                                    wrapMode: Text.WordWrap
                                    elide: Text.ElideNone
                                    lineHeight: 1.3
                                    onLinkActivated: url => Qt.openUrlExternally(url)
                                }

                                // Block quote: an accent rule down the side.
                                RowLayout {
                                    visible: blk.kind === "quote"
                                    Layout.fillWidth: true
                                    Layout.topMargin: 6
                                    spacing: 10
                                    Rectangle { Layout.fillHeight: true; Layout.preferredWidth: 2; color: Qt.alpha(help.theme.accent, .7) }
                                    Label {
                                        Layout.fillWidth: true
                                        text: blk.kind === "quote" ? Md.inline(blk.body, help.theme.yellow, help.theme.accent) : ""
                                        textFormat: Text.StyledText
                                        wrapMode: Text.WordWrap
                                        elide: Text.ElideNone
                                        lineHeight: 1.3
                                        opacity: .8
                                    }
                                }

                                // Fenced code.
                                Rectangle {
                                    visible: blk.kind === "code"
                                    Layout.fillWidth: true
                                    Layout.topMargin: 6
                                    implicitHeight: codeText.implicitHeight + 16
                                    color: Qt.alpha(help.theme.foreground, .07)
                                    border.width: 1
                                    border.color: Qt.alpha(help.theme.foreground, .14)
                                    Label {
                                        id: codeText
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: blk.kind === "code" ? blk.body : ""
                                        wrapMode: Text.NoWrap
                                        elide: Text.ElideRight
                                        color: help.theme.yellow
                                    }
                                }

                                // Bullet list.
                                ColumnLayout {
                                    visible: blk.kind === "ul"
                                    Layout.fillWidth: true
                                    Layout.topMargin: 6
                                    spacing: 6
                                    Repeater {
                                        model: blk.kind === "ul" ? blk.modelData.items : []
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Label { Layout.alignment: Qt.AlignTop; text: "·"; color: help.theme.accent }
                                            Label {
                                                Layout.fillWidth: true
                                                text: Md.inline(modelData, help.theme.yellow, help.theme.accent)
                                                textFormat: Text.StyledText
                                                wrapMode: Text.WordWrap
                                                elide: Text.ElideNone
                                                lineHeight: 1.3
                                            }
                                        }
                                    }
                                }

                                // Table. Cells keep their natural width so the
                                // frequency columns line up down the page; a
                                // table wider than the window scrolls sideways
                                // rather than wrapping its numbers.
                                Rectangle {
                                    id: tbl
                                    visible: blk.kind === "table"
                                    Layout.fillWidth: true
                                    Layout.topMargin: 8
                                    implicitHeight: grid.implicitHeight + 2
                                    color: "transparent"
                                    border.width: 1
                                    border.color: Qt.alpha(help.theme.foreground, .18)
                                    clip: true
                                    Flickable {
                                        id: cells
                                        anchors.fill: parent
                                        anchors.margins: 1
                                        contentWidth: grid.width
                                        contentHeight: grid.implicitHeight
                                        flickableDirection: Flickable.HorizontalFlick
                                        boundsBehavior: Flickable.StopAtBounds
                                        clip: true
                                        GridLayout {
                                            id: grid
                                            columns: blk.kind === "table" ? blk.modelData.head.length : 1
                                            columnSpacing: 0
                                            rowSpacing: 0
                                            width: Math.max(cells.width, implicitWidth)
                                            Repeater {
                                                model: blk.kind === "table" ? Md.flatten(blk.modelData) : []
                                                delegate: Rectangle {
                                                    id: cell
                                                    required property var modelData
                                                    readonly property bool head: modelData.row < 0
                                                    // Fill the column, or the
                                                    // row shading stops where
                                                    // the text does; the slack
                                                    // still goes to column one.
                                                    Layout.fillWidth: true
                                                    Layout.horizontalStretchFactor: modelData.col === 0 ? 1 : 0
                                                    Layout.fillHeight: true
                                                    implicitWidth: cellText.implicitWidth + 20
                                                    implicitHeight: cellText.implicitHeight + 11
                                                    color: cell.head ? Qt.alpha(help.theme.accent, .17)
                                                        : modelData.row % 2 ? Qt.alpha(help.theme.foreground, .05) : "transparent"
                                                    Label {
                                                        id: cellText
                                                        anchors.left: parent.left
                                                        anchors.leftMargin: 10
                                                        anchors.right: parent.right
                                                        anchors.rightMargin: 10
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        text: Md.inline(cell.modelData.text, help.theme.yellow, help.theme.accent)
                                                        textFormat: Text.StyledText
                                                        font.bold: cell.head
                                                        color: cell.head ? help.theme.accent : help.theme.foreground
                                                        elide: Text.ElideNone
                                                        onLinkActivated: url => Qt.openUrlExternally(url)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            Layout.topMargin: 24
                            visible: help.shown.length === 0
                            horizontalAlignment: Text.AlignHCenter
                            opacity: .45
                            text: help.blocks.length === 0 ? "docs/frequencies.md not found" : "nothing matches “" + help.query + "”"
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: false
                Caption {
                    Layout.fillWidth: true
                    text: "receive only · numbers inside a band are convention, edges are law · docs/frequencies.md"
                }
                Control { text: "close"; onClicked: help.session.helpOpen = false }
            }
        }
    }
}
