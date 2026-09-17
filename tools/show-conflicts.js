// Prints every merge-conflict hunk (ours / theirs) in the given files.
const fs = require("fs");
for (const f of process.argv.slice(2)) {
  const lines = fs.readFileSync(f, "utf8").split(/\r?\n/);
  let i = 0, n = 0;
  while (i < lines.length) {
    if (lines[i].startsWith("<<<<<<< ")) {
      const a = i; let m = i; while (lines[m] !== "=======") m++;
      let b = m; while (!lines[b].startsWith(">>>>>>> ")) b++;
      n++;
      console.log(`=== ${f} hunk ${n} (lines ${a + 1}-${b + 1})`);
      console.log("--- OURS:\n" + lines.slice(a + 1, m).join("\n"));
      console.log("--- THEIRS:\n" + lines.slice(m + 1, b).join("\n"));
      i = b + 1;
    } else i++;
  }
}
