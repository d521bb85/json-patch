import { readFileSync, writeFileSync } from "node:fs";
import jsonpatch from "fast-json-patch";

const [dir, millis, ...names] = process.argv.slice(2);
for (const name of names) {
  const doc = readFileSync(`${dir}/${name}.doc.json`, "utf8");
  const patch = readFileSync(`${dir}/${name}.patch.json`, "utf8");
  const times = [];
  let result = "";
  const started = performance.now();
  while (times.length < 5 || performance.now() - started < Number(millis)) {
    const start = process.hrtime.bigint();
    const value = jsonpatch.applyPatch(JSON.parse(doc), JSON.parse(patch), true, true).newDocument;
    result = JSON.stringify(value);
    times.push(process.hrtime.bigint() - start);
  }
  times.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  writeFileSync(`${dir}/out/node.${name}.json`, result);
  console.log(name, times[times.length >> 1].toString());
}
