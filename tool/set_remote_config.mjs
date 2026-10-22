// Merges a release's version numbers into a Remote Config template.
//
//   node tool/set_remote_config.mjs <source.json> <out.json> <versionCode> <versionName> [--enforce]
//
// <source.json> is the live template (`firebase remoteconfig:get -o …`) or,
// when that couldn't be read, the repo's remoteconfig.template.json. Every
// other parameter, condition and group in it is kept as-is.
//
// Always:     latest_version_code = max(current, versionCode)
// --enforce:  also min_version_code = versionCode, force_update = true and
//             min_required_version = versionName (the key 3.2.1 and older
//             read) — run only once Google Play shows the release as live,
//             or users are blocked with nothing newer to install.

import { readFileSync, writeFileSync } from "node:fs";

const [src, out, codeArg, name, ...flags] = process.argv.slice(2);
const code = Number.parseInt(codeArg, 10);
if (!src || !out || !Number.isInteger(code) || code <= 0 || !name) {
  console.error(
    "usage: node tool/set_remote_config.mjs <source.json> <out.json> <versionCode> <versionName> [--enforce]",
  );
  process.exit(2);
}
const enforce = flags.includes("--enforce");

const template = JSON.parse(readFileSync(src, "utf8"));
// Server metadata; deploy rejects or ignores it.
delete template.version;
delete template.etag;
template.parameters ??= {};

function current(key) {
  const v = template.parameters[key]?.defaultValue?.value;
  const n = Number.parseInt(v ?? "", 10);
  return Number.isInteger(n) ? n : 0;
}

function set(key, value, valueType, description) {
  const p = (template.parameters[key] ??= {});
  p.defaultValue = { value: String(value) };
  p.valueType ??= valueType;
  if (description && !p.description) p.description = description;
}

// Where "Update Now" sends users; only filled in when missing.
const PLAY_URL = "https://play.google.com/store/apps/details?id=com.tbtrapp";
for (const key of ["playstore_url", "update_url_playstore"]) {
  if (!template.parameters[key]?.defaultValue?.value) {
    set(key, PLAY_URL, "STRING", "Store listing opened by Update Now.");
  }
}

const latest = Math.max(current("latest_version_code"), code);
set("latest_version_code", latest, "NUMBER",
  "3.2.2+: newest version code available.");

if (enforce) {
  set("min_version_code", code, "NUMBER",
    "3.2.2+: lowest allowed version code (the +N in pubspec.yaml).");
  set("force_update", "true", "BOOLEAN",
    "3.2.2+ (version code 25+): block versions below min_version_code.");
  set("min_required_version", name, "STRING",
    "3.2.1 and older: lowest allowed version NAME.");
}

writeFileSync(out, JSON.stringify(template, null, 2) + "\n");
console.log(
  `Remote Config: latest_version_code=${latest}` +
    (enforce
      ? `, min_version_code=${code}, min_required_version=${name}, force_update=true`
      : ` (min_version_code unchanged at ${current("min_version_code")})`),
);
