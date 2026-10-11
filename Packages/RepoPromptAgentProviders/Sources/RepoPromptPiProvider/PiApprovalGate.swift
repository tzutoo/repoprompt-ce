import Foundation

/// Built-in pi tools that Full Access would otherwise run without confirmation.
public enum PiApprovalGate: Sendable {
    public static let gatedToolNames: [String] = ["bash", "edit", "write"]

    /// One-file extension: `tool_call` → RPC `confirm` when `ctx.hasUI`, else fail closed.
    public static func extensionSource() -> String {
        """
        export default function (pi) {
          const gated = new Set(["bash", "edit", "write"]);
          pi.on("tool_call", async (event, ctx) => {
            if (!gated.has(event.toolName)) return;
            if (!ctx.hasUI) {
              return { block: true, reason: "pi gate: no UI" };
            }
            const title = "Allow pi " + event.toolName + "?";
            const message = event.toolName === "bash"
              ? "pi wants to run a shell command."
              : "pi wants to change a file with " + event.toolName + ".";
            const confirmed = await ctx.ui.confirm(title, message);
            if (!confirmed) {
              return { block: true, reason: event.toolName + " was not approved" };
            }
          });
        }
        """
    }
}
