const fs = require('fs');
const path = require('path');

const rootDir = path.resolve(__dirname, '..');
const rawTag =
  process.argv[2] ||
  process.env.APP_VERSION ||
  process.env.GITHUB_REF_NAME ||
  (process.env.GITHUB_REF ? process.env.GITHUB_REF.replace(/^refs\/tags\//, '') : '') ||
  '';

const tag = rawTag.trim();
const cleanVer = tag.replace(/^[vV]/, '').trim();
const changelogPath = process.env.CHANGELOG_FILE || path.join(rootDir, 'CHANGELOG.md');

console.log(`[extract-changelog] Target tag: "${tag}" (clean version: "${cleanVer}")`);
console.log(`[extract-changelog] Reading changelog from: ${changelogPath}`);

function extractSection(content, version) {
  if (!content) return null;

  const lines = content.split(/\r?\n/);
  const versionPatterns = [];

  if (version) {
    const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    versionPatterns.push(new RegExp(`^##\\s+\\[?v?${escaped}\\]?(?:\\s+-\\s+.*|\\s*)?$`, 'i'));
  }

  let startIndex = -1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    for (const pattern of versionPatterns) {
      if (pattern.test(line)) {
        startIndex = i + 1;
        break;
      }
    }
    if (startIndex !== -1) break;
  }

  if (startIndex === -1) {
    return null;
  }

  const sectionLines = [];
  for (let i = startIndex; i < lines.length; i++) {
    const line = lines[i];
    // Stop at the next level 1 or level 2 header
    if (/^##?\s+/.test(line)) {
      break;
    }
    // Stop if reference link definitions start at the bottom of the changelog
    if (/^\[[^\]]+\]:\s*https?:\/\//.test(line)) {
      break;
    }
    sectionLines.push(line);
  }

  const result = sectionLines.join('\n').trim();
  return result.length > 0 ? result : null;
}

function getFallbackBody(versionTag) {
  const displayTag = versionTag || 'Latest';
  return [
    `FolioSync release ${displayTag}.`,
    '',
    '### Installation',
    'Extract `FolioSync.koplugin` into your KOReader `plugins/` directory.',
  ].join('\n');
}

let releaseNotes = '';

if (fs.existsSync(changelogPath)) {
  const content = fs.readFileSync(changelogPath, 'utf8');
  const extracted = extractSection(content, cleanVer);

  if (extracted) {
    releaseNotes = extracted;
    console.log(`[extract-changelog] Successfully extracted release notes for version "${cleanVer}".`);
  } else {
    console.warn(`[extract-changelog] No changelog section found matching version "${cleanVer}". Using fallback.`);
    releaseNotes = getFallbackBody(tag || cleanVer);
  }
} else {
  console.warn(`[extract-changelog] CHANGELOG file not found at ${changelogPath}. Using fallback.`);
  releaseNotes = getFallbackBody(tag || cleanVer);
}

// 1. Output to GITHUB_OUTPUT if available
if (process.env.GITHUB_OUTPUT) {
  try {
    const delimiter = `EOF_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
    const outputData = [
      `changelog<<${delimiter}`,
      releaseNotes,
      delimiter,
      `version=${cleanVer}`,
      `tag=${tag || ('v' + cleanVer)}`,
      '',
    ].join('\n');

    fs.appendFileSync(process.env.GITHUB_OUTPUT, outputData, 'utf8');
    console.log('[extract-changelog] Set "changelog" output in GITHUB_OUTPUT.');
  } catch (err) {
    console.error('[extract-changelog] Failed to write to GITHUB_OUTPUT:', err);
  }
}

// 2. Output to GITHUB_ENV if available
if (process.env.GITHUB_ENV) {
  try {
    const delimiter = `EOF_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
    const envData = [
      `RELEASE_BODY<<${delimiter}`,
      releaseNotes,
      delimiter,
      '',
    ].join('\n');

    fs.appendFileSync(process.env.GITHUB_ENV, envData, 'utf8');
    console.log('[extract-changelog] Set "RELEASE_BODY" environment variable in GITHUB_ENV.');
  } catch (err) {
    console.error('[extract-changelog] Failed to write to GITHUB_ENV:', err);
  }
}

// 3. Write release notes to dist/release-notes.md for easy inspection / file-based usage
try {
  const distDir = path.join(rootDir, 'dist');
  if (!fs.existsSync(distDir)) {
    fs.mkdirSync(distDir, { recursive: true });
  }
  fs.writeFileSync(path.join(distDir, 'release-notes.md'), releaseNotes, 'utf8');
  console.log(`[extract-changelog] Written release notes to ${path.join(distDir, 'release-notes.md')}`);
} catch (err) {
  console.warn('[extract-changelog] Note: Could not write release-notes.md to dist:', err.message);
}

console.log('\n--- EXTRACTED RELEASE NOTES ---');
console.log(releaseNotes);
console.log('-------------------------------\n');
