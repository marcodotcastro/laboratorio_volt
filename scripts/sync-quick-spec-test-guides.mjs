import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "..");
const SOURCE_ROOT = path.join(REPO_ROOT, "specs", "quick-specs");
const TARGET_ROOT = path.join(REPO_ROOT, "website", "src", "content", "docs", "releases", "guides");
const CARD_NAME_REGEX = /^CC-\d+$/;

async function ensureDir(dirPath) {
  await fs.mkdir(dirPath, { recursive: true });
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function listCardDirectories() {
  const entries = await fs.readdir(SOURCE_ROOT, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isDirectory() && CARD_NAME_REGEX.test(entry.name))
    .map((entry) => entry.name)
    .sort((a, b) => a.localeCompare(b, "pt-BR", { numeric: true }));
}

function slugForCard(cardName) {
  return cardName.toLowerCase();
}

function stripLeadingH1(markdown) {
  return markdown.replace(/^# .+\r?\n(\r?\n)?/, "");
}

async function writeGuidePage(cardName) {
  const sourceGuidePath = path.join(SOURCE_ROOT, cardName, "test-guide.md");
  if (!(await fileExists(sourceGuidePath))) return false;

  const sourceGuideContent = stripLeadingH1(await fs.readFile(sourceGuidePath, "utf8"));
  const targetPagePath = path.join(TARGET_ROOT, `${slugForCard(cardName)}.md`);
  const generatedContent = `---
title: Guia de Teste
sidebar:
  label: ${cardName}
---

${sourceGuideContent}
`;

  await fs.writeFile(targetPagePath, generatedContent, "utf8");
  return true;
}

async function cleanGeneratedGuidePages() {
  if (!(await fileExists(TARGET_ROOT))) return;

  const entries = await fs.readdir(TARGET_ROOT, { withFileTypes: true });
  const filesToDelete = entries
    .filter((entry) => entry.isFile() && /^cc-\d+\.md$/i.test(entry.name))
    .map((entry) => path.join(TARGET_ROOT, entry.name));

  await Promise.all(filesToDelete.map((filePath) => fs.unlink(filePath)));
}

async function run() {
  await ensureDir(TARGET_ROOT);
  await cleanGeneratedGuidePages();

  if (!(await fileExists(SOURCE_ROOT))) {
    process.stdout.write("Quick-spec test guides published: 0\n");
    return;
  }

  const cards = await listCardDirectories();
  let publishedCount = 0;

  for (const card of cards) {
    const published = await writeGuidePage(card);
    if (published) publishedCount += 1;
  }

  process.stdout.write(`Quick-spec test guides published: ${publishedCount}\n`);
}

run().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
