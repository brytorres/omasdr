import Quickshell

// Standalone launcher for development: `quickshell -p ui/shell.qml` opens
// the expanded window without the Omarchy shell. The bar widget needs the
// shell's qs.Ui and is exercised through scripts/dev-link.sh instead.
ShellRoot {
    RadioWindow { standalone: true }
}
