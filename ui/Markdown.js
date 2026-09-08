.pragma library

// The smallest markdown reader that renders docs/frequencies.md well: the
// blocks that document actually uses, and nothing else. Qt's own
// Text.MarkdownText draws tables with no control over borders, spacing or
// colour, and this reference is mostly tables, so it is parsed into blocks
// the window can style like the rest of OmaSDR.
//
// Block shapes:
//   {type: "h",     level, text}
//   {type: "p",     text}
//   {type: "quote", text}
//   {type: "code",  text}
//   {type: "ul",    items: [text]}
//   {type: "table", head: [text], rows: [[text]]}

function cells(line) {
    return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map(function (c) { return c.trim(); });
}

function parse(src) {
    var lines = String(src).replace(/\r\n/g, "\n").split("\n");
    var blocks = [];
    var i = 0;
    while (i < lines.length) {
        var line = lines[i];
        if (/^\s*$/.test(line)) { i++; continue; }

        if (/^```/.test(line)) {
            i++;
            var code = [];
            while (i < lines.length && !/^```/.test(lines[i])) code.push(lines[i++]);
            i++;
            blocks.push({type: "code", text: code.join("\n")});
            continue;
        }

        var heading = /^(#{1,4})\s+(.*)$/.exec(line);
        if (heading) {
            blocks.push({type: "h", level: heading[1].length, text: heading[2].trim()});
            i++;
            continue;
        }

        if (/^>/.test(line)) {
            var quote = [];
            while (i < lines.length && /^>/.test(lines[i])) quote.push(lines[i++].replace(/^>\s?/, ""));
            blocks.push({type: "quote", text: quote.join(" ").replace(/\s+/g, " ").trim()});
            continue;
        }

        if (/^\s*[-*]\s+/.test(line)) {
            var items = [];
            while (i < lines.length && !/^\s*$/.test(lines[i])) {
                if (/^\s*[-*]\s+/.test(lines[i])) items.push(lines[i].replace(/^\s*[-*]\s+/, ""));
                else if (items.length) items[items.length - 1] += " " + lines[i].trim();
                else break;
                i++;
            }
            blocks.push({type: "ul", items: items});
            continue;
        }

        // A table is a pipe row followed by a dashed separator row.
        if (/^\|/.test(line) && i + 1 < lines.length && /^\|[\s:|-]+$/.test(lines[i + 1])) {
            var head = cells(line);
            i += 2;
            var rows = [];
            while (i < lines.length && /^\|/.test(lines[i])) rows.push(cells(lines[i++]));
            blocks.push({type: "table", head: head, rows: rows});
            continue;
        }

        var para = [];
        while (i < lines.length && !/^\s*$/.test(lines[i]) && !/^[#>|]/.test(lines[i])
               && !/^```/.test(lines[i]) && !/^\s*[-*]\s+/.test(lines[i])) para.push(lines[i++]);
        blocks.push({type: "p", text: para.join(" ").replace(/\s+/g, " ").trim()});
    }
    return blocks;
}

// Markdown inline spans to the StyledText subset QML's Text understands.
// Escaping comes first so the document can never inject markup.
function inline(text, codeColor, linkColor) {
    var s = String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    s = s.replace(/`([^`]+)`/g, '<font color="' + codeColor + '">$1</font>');
    s = s.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
    s = s.replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<i>$2</i>");
    s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2"><font color="' + linkColor + '">$1</font></a>');
    return s;
}

function plain(text) {
    return String(text).replace(/[`*_]/g, "").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1").toLowerCase();
}

// Flatten a table into cells the view can lay out in one Repeater, each
// carrying the column and row it belongs to so the delegate can shade it.
function flatten(block) {
    var out = [];
    var c;
    for (c = 0; c < block.head.length; c++) out.push({text: block.head[c], col: c, row: -1});
    for (var r = 0; r < block.rows.length; r++)
        for (c = 0; c < block.head.length; c++)
            out.push({text: block.rows[r][c] === undefined ? "" : block.rows[r][c], col: c, row: r});
    return out;
}

function blockText(block) {
    if (block.type === "ul") return plain(block.items.join(" "));
    if (block.type === "table") return plain(block.head.join(" ") + " " + block.rows.map(function (r) { return r.join(" "); }).join(" "));
    return plain(block.text);
}

// Search keeps context: a heading whose own text matches brings its whole
// section, and a section with a match keeps its heading so the hit is never
// left floating without one. Tables narrow to the rows that match.
function filter(blocks, query) {
    var q = String(query).trim().toLowerCase();
    if (q === "") return blocks;

    var hit = [], whole = [];
    var i, j;
    for (i = 0; i < blocks.length; i++) {
        hit.push(blocks[i].type !== "h" && blockText(blocks[i]).indexOf(q) >= 0);
        whole.push(false);
    }

    // A matching heading marks everything under it, down to the next heading
    // of the same or a higher level, and marks it as kept whole so a table in
    // that section is not then narrowed to its matching rows.
    for (i = 0; i < blocks.length; i++) {
        if (blocks[i].type !== "h" || blockText(blocks[i]).indexOf(q) < 0) continue;
        hit[i] = true;
        for (j = i + 1; j < blocks.length; j++) {
            if (blocks[j].type === "h" && blocks[j].level <= blocks[i].level) break;
            hit[j] = whole[j] = true;
        }
    }

    // Any surviving block pulls its enclosing headings back in, so a hit is
    // never left floating without the section it came from.
    for (i = 0; i < blocks.length; i++) {
        if (!hit[i] || blocks[i].type === "h") continue;
        var level = 9;
        for (var k = i - 1; k >= 0 && level > 1; k--) {
            if (blocks[k].type !== "h" || blocks[k].level >= level) continue;
            hit[k] = true;
            level = blocks[k].level;
        }
    }

    var out = [];
    for (i = 0; i < blocks.length; i++) {
        if (!hit[i]) continue;
        var b = blocks[i];
        if (whole[i] || b.type === "h" || plain(blockHead(b)).indexOf(q) >= 0) { out.push(b); continue; }
        if (b.type === "table") {
            var rows = b.rows.filter(function (r) { return plain(r.join(" ")).indexOf(q) >= 0; });
            out.push(rows.length ? {type: "table", head: b.head, rows: rows} : b);
            continue;
        }
        if (b.type === "ul") {
            var items = b.items.filter(function (it) { return plain(it).indexOf(q) >= 0; });
            out.push(items.length ? {type: "ul", items: items} : b);
            continue;
        }
        out.push(b);
    }
    return out;
}

// A table's column headers, so a search for a column name keeps every row.
function blockHead(block) {
    return block.type === "table" ? block.head.join(" ") : "";
}
