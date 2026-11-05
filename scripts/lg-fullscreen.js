// Looking Glass on Wayland asks for full screen before its first configure, so KWin flags its window
// full screen but leaves it at the client's default size. Re-entering full screen makes KWin size it to
// the output. A no-op once the window fills its output.
for (const w of workspace.windowList()) {
    if (String(w.resourceClass) !== "looking-glass-client" || !w.fullScreen) continue;
    const out = w.output.geometry, g = w.frameGeometry;
    if (g.width < out.width || g.height < out.height) {
        w.fullScreen = false;
        w.fullScreen = true;
    }
}
