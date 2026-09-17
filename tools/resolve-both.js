// Resolves every conflict hunk in FILE by keeping OURS, then GLUE lines, then
// THEIRS. GLUE is a JSON array of lines (e.g. the closing `end)` that git left
// outside the hunk). Preserves the file's EOL.
//   node tools/resolve-both.js FILE [GLUE_JSON]
const fs = require("fs");
const [f, glueJson] = process.argv.slice(2);
const glue = glueJson ? JSON.parse(glueJson) : [];
const raw = fs.readFileSync(f, "utf8");
const eol = raw.includes("\r\n") ? "\r\n" : "\n";
const lines = raw.split(/\r?\n/);
const out = [];
let i = 0;
while (i < lines.length) {
  if (lines[i].startsWith("<<<<<<< ")) {
    let m = i; while (lines[m] !== "=======") m++;
    let b = m; while (!lines[b].startsWith(">>>>>>> ")) b++;
    out.push(...lines.slice(i + 1, m), ...glue, ...lines.slice(m + 1, b));
    i = b + 1;
  } else out.push(lines[i++]);
}
fs.writeFileSync(f, out.join(eol));
