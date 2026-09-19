import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "..");
const SOURCE_ROOT = path.join(REPO_ROOT, "specs", "crm");
const TARGET_ROOT = path.join(REPO_ROOT, "website", "src", "content", "docs", "specs");
const SEARCH_INDEX_PATH = path.join(REPO_ROOT, "website", "public", "specs-search-index.json");
const IN_DIR_REGEX = /^IN-\d{3}-.+$/;

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

function inSort(a, b) {
  return a.localeCompare(b, "pt-BR", { numeric: true });
}

function stripLeadingFrontmatter(markdown) {
  const normalized = markdown.replace(/^\uFEFF/, "");
  if (!normalized.startsWith("---")) return normalized;

  const lines = normalized.split(/\r?\n/);
  if (lines[0].trim() !== "---") return normalized;

  const closingIndex = lines.findIndex((line, index) => index > 0 && line.trim() === "---");
  if (closingIndex === -1) return normalized;

  return lines.slice(closingIndex + 1).join("\n").replace(/^\n+/, "");
}

function normalizeSearchText(value) {
  return (value || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\s+/g, " ")
    .trim();
}

function slugifyHeading(value) {
  return (value || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-");
}

function extractTopicEntries(markdown, { initiative, section, urlBase }) {
  const lines = markdown.split(/\r?\n/);
  const entries = [];
  const slugCounts = new Map();
  let currentH2 = "";
  let currentH3 = "";

  for (const line of lines) {
    const match = line.match(/^(#{2,4})\s+(.+)$/);
    if (!match) continue;

    const level = match[1].length;
    const heading = match[2].replace(/[*_`]/g, "").trim();
    if (!heading) continue;

    if (level === 2) currentH2 = heading;
    if (level === 3) currentH3 = heading;
    if (level < 3) continue;

    const parentTopic = level === 3 ? currentH2 : currentH3 || currentH2;

    const baseSlug = slugifyHeading(heading);
    if (!baseSlug) continue;

    const count = (slugCounts.get(baseSlug) ?? 0) + 1;
    slugCounts.set(baseSlug, count);
    const slug = count > 1 ? `${baseSlug}-${count}` : baseSlug;

    entries.push({
      initiative,
      section,
      heading,
      parentTopic: parentTopic || "",
      level,
      pageUrl: urlBase,
      searchText: normalizeSearchText(`${initiative} ${section} ${parentTopic} ${heading}`),
    });
  }

  return entries;
}

async function listInDirectories() {
  if (!(await fileExists(SOURCE_ROOT))) return [];

  const entries = await fs.readdir(SOURCE_ROOT, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isDirectory() && IN_DIR_REGEX.test(entry.name))
    .map((entry) => entry.name)
    .sort(inSort);
}

async function cleanTargetRoot() {
  await fs.rm(TARGET_ROOT, { recursive: true, force: true });
  await ensureDir(TARGET_ROOT);
}

async function writeArtifactPage(inDirectory, sourceFileName, pageSlug, pageTitle) {
  const sourcePath = path.join(SOURCE_ROOT, inDirectory, sourceFileName);
  if (!(await fileExists(sourcePath))) return false;

  const targetDir = path.join(TARGET_ROOT, inDirectory);
  await ensureDir(targetDir);

  const sourceContent = stripLeadingFrontmatter(await fs.readFile(sourcePath, "utf8"));
  const targetPath = path.join(targetDir, `${pageSlug}.md`);
  const generatedContent = `---
title: ${pageTitle}
sidebar:
  label: ${pageTitle}
---

${sourceContent}
`;

  await fs.writeFile(targetPath, generatedContent, "utf8");
  return sourceContent;
}

async function writeSearchIndex(entries) {
  await ensureDir(path.dirname(SEARCH_INDEX_PATH));
  await fs.writeFile(SEARCH_INDEX_PATH, JSON.stringify(entries), "utf8");
}

async function run() {
  await cleanTargetRoot();

  const inDirectories = await listInDirectories();
  let publishedCount = 0;
  const searchEntries = [];

  for (const inDirectory of inDirectories) {
    const initiative = inDirectory.match(/^IN-\d{3}/)?.[0] ?? inDirectory;

    const epicsContent = await writeArtifactPage(inDirectory, "epics.md", "epics", "Epics");
    if (epicsContent) {
      publishedCount += 1;
      searchEntries.push(
        ...extractTopicEntries(epicsContent, {
          initiative,
          section: "Epics",
          urlBase: `/specs/${inDirectory.toLowerCase()}/epics/`,
        })
      );
    }

    const prdContent = await writeArtifactPage(inDirectory, "prd.md", "prd", "PRD");
    if (prdContent) {
      publishedCount += 1;
      searchEntries.push(
        ...extractTopicEntries(prdContent, {
          initiative,
          section: "PRD",
          urlBase: `/specs/${inDirectory.toLowerCase()}/prd/`,
        })
      );
    }
  }

  await writeSearchIndex(searchEntries);
  process.stdout.write(`Planning artifact pages published: ${publishedCount}\n`);
}

run().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
