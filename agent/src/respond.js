// respond.js — turns a mention + the board's contents into reply text.
//
// This is the only file that talks to the Claude API. The rest of the
// agent is sync plumbing and works without credentials — set
// ASSISTANT_CANNED=1 to reply with a fixed acknowledgement instead of
// calling the model (useful for testing the Automerge round trip;
// the canned path still renders the board so the vision pipeline is
// exercised end-to-end).
//
// The model gets two views of the same board: a PNG render (the
// actual sketches — see render.js for how it mirrors FieldView's
// geometry) and a text description (exact positions, distances to the
// question pin, comment history). Vision + coordinates beat either
// alone.
//
// The client resolves credentials from the environment on its own
// (ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, or an `ant auth login`
// profile) — no key is stored in this repo.

import Anthropic from "@anthropic-ai/sdk";
import { describeBoard } from "./assistant.js";
import { renderBoardPNG } from "./render.js";

const SYSTEM_PROMPT = `You are the on-board assistant inside Sceneflow, a \
collaborative canvas where filmmakers sketch storyboard frames ("snapshots"), \
label them with text notes, and connect them with arrows to plan scenes.

A collaborator has pinned a comment mentioning you. You get a rendered image \
of the board (frames with their sketches, arrows, labels; the question's pin \
is marked with a red ring) plus a text description with exact positions. \
Frame numbers match between the two. Read the sketches for what they are — \
rough boards: judge staging, composition, eyelines, screen direction, \
coverage, the 180-degree line, and shot progression, not draftsmanship.

Your reply is pinned to the field as a small comment, so keep it under \
120 words, concrete, and specific to this board. No markdown — comments \
render as plain text.`;

let client = null;

export async function composeReply(doc, mention) {
  const rendered = renderBoardPNG(doc, mention);

  if (process.env.ASSISTANT_CANNED === "1") {
    const vision = rendered
      ? `rendered the board at ${rendered.width}x${rendered.height}`
      : "board has nothing visual yet";
    return `I'm connected and I can see the board (canned reply — no model call; ${vision}). You asked: "${mention.text}"`;
  }

  client ??= new Anthropic();

  const content = [];
  if (rendered) {
    content.push({
      type: "image",
      source: {
        type: "base64",
        media_type: "image/png",
        data: rendered.png.toString("base64"),
      },
    });
  }
  content.push({
    type: "text",
    text:
      (rendered ? "" : "(The board has nothing visual to render yet.)\n") +
      `Board contents:\n${describeBoard(doc, mention)}\n\n` +
      `${mention.authorName} pinned at (${Math.round(mention.x)}, ${Math.round(mention.y)}): "${mention.text}"`,
  });

  const response = await client.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 16000,
    thinking: { type: "adaptive" },
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content }],
  });

  const text = response.content
    .filter(block => block.type === "text")
    .map(block => block.text)
    .join("\n")
    .trim();
  if (!text) throw new Error(`model returned no text (stop_reason: ${response.stop_reason})`);
  return text;
}
