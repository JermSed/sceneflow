// apps/drive.js — external app #1: Google Drive.
//
// Drive is where the footage actually lives. The agent needs three
// things from it and nothing else:
//
//   1. the catalog of clips in a named folder,
//   2. enough metadata per clip to reason about it (duration,
//      resolution, shot date, and the filename — which on a real set
//      carries most of the meaning: "alley_wide_02_take3.mov"),
//   3. the bytes of the clips it decides to use, cached locally so
//      Resolve can import them from disk.
//
// Auth is OAuth2 with a refresh token minted once by
// `npm run auth:drive` and kept in agent/.state/drive-token.json,
// which is gitignored. Nothing secret lives in the repo.

import { google } from "googleapis";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pipeline } from "node:stream/promises";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const STATE_DIR = path.resolve(HERE, "../../.state");
const TOKEN_PATH = path.join(STATE_DIR, "drive-token.json");
const CLIENT_PATH = path.join(STATE_DIR, "drive-client.json");
export const MEDIA_CACHE = path.join(STATE_DIR, "media");

/** Video mime types we treat as footage. Drive reports these
 * reliably; extension sniffing is the fallback for the odd codec
 * Drive files as application/octet-stream. */
const VIDEO_EXT = /\.(mov|mp4|mxf|m4v|avi|braw|r3d|mkv|prores)$/i;

export function driveConfigured() {
  return fs.existsSync(TOKEN_PATH) && fs.existsSync(CLIENT_PATH);
}

export function loadOAuthClient() {
  if (!fs.existsSync(CLIENT_PATH)) {
    throw new Error(
      `Google OAuth client not found at ${CLIENT_PATH}.\n` +
      `Download a Desktop-app OAuth client JSON from console.cloud.google.com ` +
      `(APIs & Services > Credentials) and save it there, then run: npm run auth:drive`,
    );
  }
  const raw = JSON.parse(fs.readFileSync(CLIENT_PATH, "utf8"));
  const cfg = raw.installed ?? raw.web ?? raw;
  const client = new google.auth.OAuth2(
    cfg.client_id,
    cfg.client_secret,
    // Loopback redirect; the port is chosen at auth time and appended.
    "http://localhost",
  );
  if (fs.existsSync(TOKEN_PATH)) {
    client.setCredentials(JSON.parse(fs.readFileSync(TOKEN_PATH, "utf8")));
  }
  return client;
}

export function saveToken(tokens) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(TOKEN_PATH, JSON.stringify(tokens, null, 2));
  fs.chmodSync(TOKEN_PATH, 0o600);
}

function api() {
  return google.drive({ version: "v3", auth: loadOAuthClient() });
}

/** Escape a value for Drive's query language (single quotes and
 * backslashes are the only metacharacters inside a quoted literal). */
function q(value) {
  return String(value).replace(/\\/g, "\\\\").replace(/'/g, "\\'");
}

/** Resolve a folder by name to its id. Exact name match, most
 * recently modified wins if the user has several. */
export async function findFolder(name) {
  const res = await api().files.list({
    q: `mimeType = 'application/vnd.google-apps.folder' and name = '${q(name)}' and trashed = false`,
    fields: "files(id, name, modifiedTime)",
    orderBy: "modifiedTime desc",
    pageSize: 10,
    supportsAllDrives: true,
    includeItemsFromAllDrives: true,
  });
  const folder = res.data.files?.[0];
  if (!folder) throw new Error(`No Drive folder named "${name}" (is it shared with this account?)`);
  return folder;
}

/**
 * The footage catalog: every video in a folder, with the metadata the
 * matcher reasons over. Paginates, because a shoot folder is not a
 * short list.
 */
export async function listFootage(folderId) {
  const drive = api();
  const clips = [];
  let pageToken;
  do {
    const res = await drive.files.list({
      q: `'${q(folderId)}' in parents and trashed = false`,
      fields:
        "nextPageToken, files(id, name, mimeType, size, createdTime, modifiedTime, " +
        "thumbnailLink, videoMediaMetadata(width, height, durationMillis))",
      pageSize: 200,
      pageToken,
      orderBy: "name",
      supportsAllDrives: true,
      includeItemsFromAllDrives: true,
    });
    for (const f of res.data.files ?? []) {
      const isVideo = f.mimeType?.startsWith("video/") || VIDEO_EXT.test(f.name ?? "");
      if (!isVideo) continue;
      const meta = f.videoMediaMetadata ?? {};
      clips.push({
        id: f.id,
        name: f.name,
        mimeType: f.mimeType,
        sizeBytes: Number(f.size) || 0,
        createdTime: f.createdTime,
        durationSeconds: meta.durationMillis ? Number(meta.durationMillis) / 1000 : null,
        width: meta.width ?? null,
        height: meta.height ?? null,
        thumbnailLink: f.thumbnailLink ?? null,
      });
    }
    pageToken = res.data.nextPageToken;
  } while (pageToken);
  return clips;
}

/** Drive's own poster frame for a clip, fetched as PNG/JPEG bytes.
 * This is what lets the matcher *see* the footage instead of guessing
 * from filenames — the difference between a real match and a
 * plausible-sounding one. `thumbnailLink` needs the OAuth token, and
 * the `=s` suffix controls the size. */
export async function fetchThumbnail(clip, size = 512) {
  if (!clip.thumbnailLink) return null;
  const auth = loadOAuthClient();
  const { token } = await auth.getAccessToken();
  const url = clip.thumbnailLink.replace(/=s\d+$/, "") + `=s${size}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) return null;
  const buf = Buffer.from(await res.arrayBuffer());
  const type = res.headers.get("content-type") ?? "image/jpeg";
  return { buffer: buf, mediaType: type.split(";")[0] };
}

/** Download a clip into the local media cache so Resolve can import
 * it from disk. Idempotent: a cached file of the right size is
 * reused, which is what makes a second `cut` run cheap. */
export async function downloadClip(clip, onProgress) {
  fs.mkdirSync(MEDIA_CACHE, { recursive: true });
  // Namespaced by Drive id so two clips with the same name on
  // different shoots can't collide in the cache.
  const dest = path.join(MEDIA_CACHE, `${clip.id}__${clip.name}`);
  if (fs.existsSync(dest)) {
    const onDisk = fs.statSync(dest).size;
    if (!clip.sizeBytes || onDisk === clip.sizeBytes) return dest;
    fs.rmSync(dest); // truncated by an interrupted earlier run
  }
  const partial = `${dest}.part`;
  const res = await api().files.get(
    { fileId: clip.id, alt: "media", supportsAllDrives: true },
    { responseType: "stream" },
  );
  onProgress?.(clip);
  await pipeline(res.data, fs.createWriteStream(partial));
  fs.renameSync(partial, dest);
  return dest;
}
