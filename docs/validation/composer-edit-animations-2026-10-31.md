# Localized composer edit animations

The composer presents each document transaction immediately. A presentation-only word plan gives newly inserted or changed words the existing purple glow/blur, staggered from left to right over at most 0.58 seconds. Surviving words keep their normal appearance. Pure deletions briefly mark one surviving boundary. Paragraph presentation identity follows canonical line IDs, then surviving word IDs, then same-position replacements; document line/word IDs remain authoritative for selections and tools.

The plan animates at most 32 changed words and 64 rendered text runs, including wrapped long words. It uses one TextRenderer animation for the paragraph, with no per-word tasks, particle canvases, incremental Room mutations, or extra Undo entries. Reduce Motion displays the final words immediately. A newer edit replaces the previous presentation plan. Large text remains subject to the preceding lazy-rendering and rewrite-memory protections.

## Verification

Seven focused checks cover one-word spelling replacement without animating neighbours, localized deletion, a 5,000-word bounded stagger, stable paragraph presentation across replacements and insertion/reordering, canonical quote IDs, seeded agent editing with one-step Undo, and refusal to edit an unseeded session. Package compilation includes the shared SwiftUI renderer.

For native visual acceptance, use `composer-debug-seed`, then `composer-debug-edit` with a JSON-encoded `[DocOp]`. The latter requires `debug.seed`, uses the actual Room agent transaction path and never starts a provider or microphone. For example, supply `[{"replaceInLine":{"lineID":"<seeded line ID>","old":"ths","new":"this"}}]`. Inspect a short capture across the 0.58-second transition; a final screenshot alone cannot establish localized animation. Recheck tapping/dragging quote anchors and immediate full-text Insert during an animation. Physical iPhone/Mac animation and large-draft acceptance belong to the combined bundle's native UAT; they are not established by the helper checks.
