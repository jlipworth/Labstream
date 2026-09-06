// Run in the Computer Use JavaScript session after cua.getApp(exact isolated app path).
// CUA is the sole UI driver. Pass an already-selected App and one named fixture mode.
// The caller must launch --ui-testing --ui-testing-fixture player, optionally with
// --ui-testing-player-buffering or --ui-testing-player-consent. Never use a live app.
async function verifyPlaybackFixture(app, mode) {
  const started = Date.now();
  const result = {schemaVersion: 1, evidenceKind: 'syntheticVisibleUI', mode,
    status: 'blocked', reason: 'precondition', axCalls: 0, screenshotCalls: 0,
    retries: 0, observedAXBytes: 0, playbackRendering: 'unproven', serverCleanup: 'unknown'};
  async function state() {
    const value = await app.getAXState({emit: false, disableDiffing: true});
    result.axCalls++; result.observedAXBytes += new TextEncoder().encode(value).length;
    return value;
  }
  function index(value, id) {
    const line = value.split('\n').find(line => line.includes('ID: '+id) &&
      (line.endsWith('ID: '+id) || line.includes('ID: '+id+',')));
    if (!line) throw new Error('missing_semantic_control');
    return Number(line.trim().match(/^\d+/)[0]);
  }
  try {
    if (!['hidden', 'buffering', 'consent'].includes(mode)) throw new Error('unsupported_mode');
    let value = await state();
    if (!value.includes('Window: "Labstream Dev — agent-player-290"')) throw new Error('wrong_identity');
    if (mode === 'hidden' && value.includes('ID: playback.playPause')) throw new Error('chrome_not_hidden');
    await app.pressKey('super+shift+k');
    value = await state();
    index(value, 'playback.surface');
    if (mode === 'consent') {
      index(value, 'playback.allowVideoTranscoding');
      await app.click(index(value, 'playback.declineVideoTranscoding'));
      value = await state();
      if (value.includes('ID: playback.allowVideoTranscoding')) throw new Error('consent_still_pending');
      result.reason = 'consent_declined';
    } else {
      index(value, 'playback.playPause');
      if (mode === 'buffering') index(value, 'playback.buffer.playPause');
      await app.click(index(value, 'playback.menu.audio'));
      value = await state();
      const close = index(value, 'playback.menu.close');
      await app.click(close);
      value = await state();
      if (value.includes('ID: playback.menu.close')) throw new Error('menu_still_open');
      await app.pressKey('super+shift+k');
      value = await state();
      index(value, 'playback.menu.audio');
      result.reason = 'reveal_and_menu_verified';
    }
    result.status = 'passed';
  } catch (error) {
    const allowed = ['unsupported_mode','wrong_identity','chrome_not_hidden','missing_semantic_control','consent_still_pending','menu_still_open'];
    result.reason = allowed.includes(error.message) ? error.message : 'ui_action_failed';
  }
  result.elapsedMs = Date.now()-started;
  return result;
}
