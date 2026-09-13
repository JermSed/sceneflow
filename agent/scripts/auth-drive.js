// auth-drive.js — one-time Google Drive consent, done locally.
//
// Opens the consent screen against a loopback redirect, catches the
// code on a throwaway localhost server, and stores the refresh token
// in agent/.state/drive-token.json (gitignored, chmod 600). Nothing
// touches the repo and no secret ever reaches the model.
//
//   1. console.cloud.google.com -> enable the Google Drive API
//   2. Credentials -> Create OAuth client ID -> Desktop app
//   3. save the downloaded JSON as agent/.state/drive-client.json
//   4. npm run auth:drive

import http from "node:http";
import { google } from "googleapis";
import { loadOAuthClient, saveToken } from "../src/apps/drive.js";

// Read-only: the agent catalogs and downloads footage, and must not
// be able to modify anything in the user's Drive.
const SCOPES = ["https://www.googleapis.com/auth/drive.readonly"];

const client = loadOAuthClient();

const server = http.createServer();
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;
const redirectUri = `http://127.0.0.1:${port}`;
client.redirectUri = redirectUri;

const url = client.generateAuthUrl({
  access_type: "offline",     // we need a refresh token, not just an hour
  prompt: "consent",          // force one so re-auth actually re-issues it
  scope: SCOPES,
  redirect_uri: redirectUri,
});

console.log("\nOpen this URL and grant access:\n");
console.log(url + "\n");

const code = await new Promise((resolve, reject) => {
  server.on("request", (req, res) => {
    const params = new URL(req.url, redirectUri).searchParams;
    const err = params.get("error");
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end(err ? `Authorization failed: ${err}` : "Sceneflow is connected to Drive. You can close this tab.");
    err ? reject(new Error(err)) : resolve(params.get("code"));
  });
  setTimeout(() => reject(new Error("timed out waiting for consent")), 5 * 60_000);
});
server.close();

const { tokens } = await client.getToken({ code, redirect_uri: redirectUri });
if (!tokens.refresh_token) {
  console.error("\nGoogle returned no refresh token. Revoke the app at " +
    "myaccount.google.com/permissions and run this again.");
  process.exit(1);
}
saveToken(tokens);
console.log("Saved agent/.state/drive-token.json");

// Prove it works rather than claiming it does.
const drive = google.drive({ version: "v3", auth: loadOAuthClient() });
const me = await drive.about.get({ fields: "user(emailAddress)" });
console.log(`Connected as ${me.data.user.emailAddress}`);
