#!/usr/bin/env node
import { access, readdir, readFile } from "node:fs/promises";
import { dirname, extname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const webDir = resolve(scriptDir, "..");
const publicBlogDir = resolve(webDir, "public/images/blog");
const scanRoots = [resolve(webDir, "content/articles"), resolve(webDir, "src")];
const textExtensions = new Set([".md", ".mdx", ".ts", ".tsx"]);
const staticAssetPattern = /\/images\/blog\/[A-Za-z0-9._+%/-]+/g;
const legacyAssetPattern = /\/api\/assets\/blog\/[A-Za-z0-9._+%/-]+/g;

async function collectFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await collectFiles(path)));
    else files.push(path);
  }
  return files;
}

async function collectTextFiles(directory) {
  return (await collectFiles(directory)).filter((file) =>
    textExtensions.has(extname(file)),
  );
}

const references = new Map();
const legacyReferences = [];
for (const root of scanRoots) {
  for (const file of await collectTextFiles(root)) {
    const text = await readFile(file, "utf8");
    for (const url of text.match(staticAssetPattern) || []) {
      const path = decodeURIComponent(url.slice("/images/blog/".length));
      if (!references.has(path)) references.set(path, []);
      references.get(path).push(file);
    }
    for (const url of text.match(legacyAssetPattern) || []) {
      legacyReferences.push({ file, url });
    }
  }
}

if (legacyReferences.length > 0) {
  console.error("Legacy Supabase blog asset references remain:");
  for (const item of legacyReferences)
    console.error(`  - ${item.file}: ${item.url}`);
  process.exitCode = 1;
}

const missing = [];
for (const path of references.keys()) {
  try {
    await access(resolve(publicBlogDir, path));
  } catch {
    missing.push(path);
  }
}

if (missing.length > 0) {
  console.error(`${missing.length} static blog asset(s) are missing:`);
  for (const path of missing) console.error(`  - ${path}`);
  process.exitCode = 1;
}

const present = (await collectFiles(publicBlogDir)).map((file) =>
  relative(publicBlogDir, file).replaceAll("\\", "/"),
);
const unreferenced = present.filter((path) => !references.has(path));
if (unreferenced.length > 0) {
  console.error(
    `${unreferenced.length} static blog asset(s) are unreferenced:`,
  );
  for (const path of unreferenced) console.error(`  - ${path}`);
  process.exitCode = 1;
}

if (!process.exitCode) {
  console.log(
    `All ${references.size} static blog asset(s) are referenced and present; no legacy Supabase blog URLs remain.`,
  );
}
