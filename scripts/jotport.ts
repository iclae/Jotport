// Scoped to launches using --extension; never installed into global pi configuration.
import { randomUUID } from "node:crypto";
import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { join } from "node:path";
export default function (pi: any) {
  const runID = process.env.JOTPORT_RUN, inbox = process.env.JOTPORT_INBOX;
  if (!runID || !inbox) return;
  let sequence = 0, turnID = 0, bound = "", reply = "";
  function emit(type: string, ctx: any, text?: string) {
    try {
      const sessionID = ctx.sessionManager.getSessionId();
      if (bound && sessionID !== bound) return; // Never relabel a switched native conversation.
      bound = sessionID;
      const eventID = randomUUID();
      const event = { schemaVersion: 1, eventID, runID, sessionID, turnID, sequence: sequence++, source: "pi", type, time: new Date().toISOString(), text };
      const temp = join(inbox!, eventID + ".tmp");
      writeFileSync(temp, JSON.stringify(event), { mode: 0o600 });
      renameSync(temp, join(inbox!, eventID + ".json"));
    } catch { /* Reporting must not influence agent decisions. */ }
  }
  pi.on("session_start", async (_: any, ctx: any) => {
    emit("bound", ctx);
    const snapshot = process.env.JOTPORT_SNAPSHOT;
    const marker = join(process.env.JOTPORT_RUN_DIR!, "prefill-attempted");
    if (!snapshot || existsSync(marker) || !ctx.hasUI || typeof ctx.ui?.setEditorText !== "function") return;
    // Claim before editor side effect: crashes cannot inject twice. Never send a message.
    try { writeFileSync(marker, "1", { flag: "wx", mode: 0o600 }); ctx.ui.setEditorText(readFileSync(snapshot, "utf8")); emit("prefilled", ctx); } catch {}
  });
  pi.on("agent_start", async (_: any, ctx: any) => { turnID++; reply = ""; emit("running", ctx); });
  pi.on("message_end", async (e: any) => {
    if (e.message?.role === "assistant") reply = (e.message.content ?? []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n");
  });
  // agent_end is NOT a final-idle event. Older pi builds remain conservatively running/unknown.
  pi.on("agent_settled", async (_: any, ctx: any) => emit("settled", ctx, reply));
  pi.on("session_shutdown", async (e: any, ctx: any) => emit(e.reason === "quit" ? "exited" : "unknown", ctx));
}
