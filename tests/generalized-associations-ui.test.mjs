import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("uses the server catalog and schema 3 association contract", async () => {
  const app = await read("src/App.jsx");
  const agent = await read("native/DefaultAppGuard.Agent/Program.cs");

  assert.match(app, /\/api\/association-catalog/);
  assert.match(app, /\/api\/associations\/inspect/);
  assert.match(app, /protectedAssociations/);
  assert.match(app, /captureCurrentExtensions/);
  assert.match(app, /更新为当前默认程序/);
  assert.doesNotMatch(app, /protectedVideoExtensions/);
  for (const category of [
    "video",
    "audio",
    "document",
    "image",
    "archive",
    "web-data",
  ]) {
    assert.ok(app.includes(category));
  }

  assert.match(agent, /MapGet\("\/api\/association-catalog"/);
  assert.match(agent, /MapPost\("\/api\/associations\/inspect"/);
  assert.match(agent, /AssociationInspectionResult/);
});

test("keeps generalized selection usable on mobile", async () => {
  const styles = await read("src/styles.css");

  assert.match(styles, /@media \(max-width: 640px\)/);
  assert.match(styles, /\.primary-nav \{[\s\S]*position: fixed/);
  assert.match(styles, /\.defaults-workspace \{[\s\S]*flex-direction: column/);
  assert.match(styles, /\.apply-area \{[\s\S]*grid-template-columns:/);
});
