const lines = require("fs").readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean);
for (const l of lines) { const b = JSON.parse(l); let r;
  try { r = { ok: true, v: Bun.YAML.parse(b) }; } catch (e) { r = { ok: false, e: String(e).slice(0, 80) }; }
  console.log(JSON.stringify(r)); }
