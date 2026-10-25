const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");

const projectRoot = join(__dirname, "..", "..");

test("Realtime Database rules protect credentials and restrict writes", () => {
  const { rules } = require(join(projectRoot, "database.rules.json"));
  assert.equal(rules[".read"], false);
  assert.equal(rules[".write"], false);
  assert.equal(rules.config, undefined);
  assert.equal(rules.wallpapers[".read"], true);
  assert.ok(rules.wallpapers[".write"] === true || rules.wallpapers[".write"] === undefined);
  assert.equal(rules.update[".read"], true);
  assert.equal(rules.update[".write"], undefined);
  assert.equal(
    rules.bugs[".read"],
    "auth != null && auth.uid === 'JaFeCtCVcbSruaViANZOVWcKQOj1'",
  );
  assert.equal(
    rules.bugs.$bugId[".write"],
    "(auth != null && auth.uid === 'JaFeCtCVcbSruaViANZOVWcKQOj1') || (!data.exists() && newData.exists())",
  );
  assert.equal(
    rules.reports[".read"],
    "auth != null && auth.uid === 'JaFeCtCVcbSruaViANZOVWcKQOj1'",
  );
  assert.equal(
    rules.reports.$reportId[".write"],
    "(auth != null && auth.uid === 'JaFeCtCVcbSruaViANZOVWcKQOj1') || (!data.exists() && newData.exists())",
  );
  assert.equal(
    rules.wallpaperReports[".read"],
    "auth != null && auth.uid === 'JaFeCtCVcbSruaViANZOVWcKQOj1'",
  );
  assert.match(rules.wallpaperReports.$reportId[".write"], /!data\.exists\(\).*newData\.hasChildren\(/);
  assert.match(rules.wallpaperReports.$reportId[".write"], /newData\.child\('status'\)\.val\(\) === 'pending'/);
  assert.match(rules.wallpaperReports.$reportId[".write"], /!newData\.child\('adminNotes'\)\.exists\(\)/);
  assert.match(rules.wallpaperReports.$reportId[".write"], /auth != null.*data\.exists\(\).*newData\.exists\(\)/);
  assert.match(rules.wallpaperReports.$reportId[".validate"], /description/);
  assert.match(rules.wallpaperReports.$reportId[".validate"], /adminNotes/);
  assert.equal(rules.wallpaperReports.$reportId.$other[".validate"], false);
  assert.equal(rules.wallpaperReports.$reportId.adminNotes[".validate"].includes("2000"), true);
  assert.doesNotMatch(
    JSON.stringify(rules.wallpaperReports.$reportId),
    /numChildren/,
  );
});

test("wallpaper report admin operations are behind verified Admin API auth", () => {
  const functions = readFileSync(join(projectRoot, "functions", "index.js"), "utf8");
  assert.match(functions, /await requireAdmin\(req\)/);
  assert.match(functions, /req\.path === "\/wallpaper-reports" && req\.method === "GET"/);
  assert.match(functions, /req\.method === "PATCH"/);
  assert.match(functions, /wallpaperReports/);
  assert.match(functions, /migrateWallpaperIds/);
});

test("admin browser code never stores or proxies Cloudinary API secrets", () => {
  const html = readFileSync(join(projectRoot, "admin_panel", "index.html"), "utf8");
  const script = readFileSync(join(projectRoot, "admin_panel", "app.js"), "utf8");
  assert.doesNotMatch(html, /api-secret|api-key/i);
  assert.doesNotMatch(script, /apiSecret|corsproxy\.io|innerHTML/i);
});

test("admin browser element references exist in the panel markup", () => {
  const html = readFileSync(join(projectRoot, "admin_panel", "index.html"), "utf8");
  const script = readFileSync(join(projectRoot, "admin_panel", "app.js"), "utf8");
  const elementIds = [...script.matchAll(/getElementById\('([^']+)'\)/g)]
    .map((match) => match[1]);

  for (const id of elementIds) {
    assert.match(html, new RegExp(`id="${id}"`), `Missing element id: ${id}`);
  }
});

test("admin API allows the local Admin Panel origins by default", () => {
  const functions = readFileSync(join(projectRoot, "functions", "index.js"), "utf8");
  assert.match(
    functions,
    /default:\s*"http:\/\/localhost:3000,http:\/\/127\.0\.0\.1:3000,http:\/\/localhost:8000,http:\/\/127\.0\.0\.1:8000/,
  );
});
