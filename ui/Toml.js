// Minimal TOML reader for Omarchy theme files: flat `key = value` lines and
// `[section]` headers become "section.key" entries. Strings, numbers, and
// booleans only, which is all colors.toml and shell.toml use. A `#` inside
// a quoted string is part of the value (hex colours), not a comment.
.pragma library

function parse(raw) {
    var out = {}, section = "";
    var lines = String(raw || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (!line || line[0] === "#") continue;
        var head = line.match(/^\[([^\]]+)\]/);
        if (head) { section = head[1].trim(); continue; }
        var kv = line.match(/^([A-Za-z0-9_.-]+)\s*=\s*(.*)$/);
        if (!kv) continue;
        var key = section ? section + "." + kv[1] : kv[1];
        var rest = kv[2].trim(), value;
        var quoted = rest.match(/^"((?:[^"\\]|\\.)*)"/) || rest.match(/^'([^']*)'/);
        if (quoted) value = quoted[1];
        else {
            value = rest.replace(/\s#.*$/, "").replace(/^#.*$/, "").trim();
            if (value === "true") value = true;
            else if (value === "false") value = false;
            else if (/^-?\d+(\.\d+)?$/.test(value)) value = Number(value);
        }
        out[key] = value;
    }
    return out;
}
