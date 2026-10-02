using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Windows;
using HoverPocket.Shell.Settings;

namespace HoverPocket.Shell.Verification;

internal sealed class UiVerifier
{
    private readonly HoverShellController _controller;
    private readonly List<string> _failures = [];

    public UiVerifier(HoverShellController controller)
    {
        _controller = controller;
    }

    public async Task<int> RunAsync()
    {
        VerifyConsole.WriteLine("UI verify: WebView2 host + bridge + provider registry + settings");

        try
        {
            var entry = _controller.Layouts[0].AccessSurface.PhysicalRect;
            var coldStart = System.Diagnostics.Stopwatch.StartNew();
            _controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top);
            if (!_controller.Panel.IsVisible || !_controller.PanelExpectedVisibleForVerify)
                _failures.Add("cold start: panel waited for WebView2 initialization before showing");
            else
                VerifyConsole.WriteLine($"PASS cold top-edge open: panel_visible_before_webview_ready=true, dispatch_ms={coldStart.Elapsed.TotalMilliseconds:0.0}");
            await _controller.ShowPanelForUiVerifyAsync();
            var ready = await _controller.Panel.WaitForUiReadyAsync(TimeSpan.FromSeconds(8));
            if (!ready)
            {
                _failures.Add("webview: UI did not report ready within 8s");
            }

            var result = ready ? await _controller.Panel.RunWebVerifyScriptAsync() : null;
            if (result is null)
            {
                _failures.Add("webview: verification script returned no result");
            }
            else
            {
                if (!result.EchoOk)
                {
                    _failures.Add("bridge: diagnostics.echo round-trip failed");
                }

                if (!result.LegacyAiLaneNotMountedOk || !result.VoiceDefaultOffOk)
                {
                    _failures.Add("voice: default-off or legacy lane absence regressed");
                }

                if (!result.VoiceTeardownVisibleOk)
                {
                    _failures.Add("voice: lane disappeared before runtime teardown completed");
                }

                if (!result.VoiceLocalizationOk)
                {
                    _failures.Add("voice: Japanese and English lane copy did not render correctly");
                }

                if (!result.VoiceTransportContractOk)
                {
                    _failures.Add("voice: WebRTC transport controls or safe error copy regressed");
                }

                if (!result.VoiceWebRtcHarnessOk)
                {
                    _failures.Add("voice: fake permission/WebRTC offer-answer cleanup failed");
                }

                if (!result.ControlsRenderedOk)
                {
                    _failures.Add("controls: three live sections did not render");
                }

                if (!result.ControlsLayoutOk)
                {
                    _failures.Add("controls: rendered sections overflowed the provider bounds");
                }

                if (!result.ControlsHitAreasOk)
                {
                    _failures.Add("controls: media buttons did not keep 32px rectangular hit areas");
                }

                if (!result.ControlsFallbackLayerOk)
                {
                    _failures.Add("controls: live preview did not retain an artwork/fallback layer");
                }

                if (!result.ControlsStableRefreshOk)
                {
                    _failures.Add("controls: unchanged refresh replaced the live preview DOM");
                }

                if (!result.ControlsBrightnessResolvedOk)
                {
                    _failures.Add("controls: background brightness detection remained in its temporary state");
                }

                if (!result.ControlsMediaActionsOk)
                {
                    _failures.Add("controls: media source activation or playback rate actions did not render");
                }

                if (!result.ClipboardStableProviderOk)
                {
                    _failures.Add("clipboard: selecting the active provider remounted the view");
                }

                if (!result.ClipboardStableRefreshOk)
                {
                    _failures.Add("clipboard: unchanged refresh replaced the rendered view");
                }

                if (!result.ClipboardSplitViewOk)
                {
                    _failures.Add("clipboard: text and image split view did not render together");
                }

                if (!result.ClipboardCenteredSplitOk)
                {
                    _failures.Add("clipboard: text and image panes were not split equally around the center divider");
                }

                if (!result.ClipboardTabsOk)
                {
                    _failures.Add("clipboard: all/favorites tabs did not switch the split view");
                }

                if (!result.ClipboardDeleteActionsOk || !result.ClipboardNoDragActionOk)
                {
                    _failures.Add("clipboard: trash actions did not replace external drag actions");
                }

                if (!result.ClipboardNoResolutionOk)
                {
                    _failures.Add("clipboard: image resolution metadata was still rendered");
                }

                if (!result.ClipboardPreviewBehaviorOk)
                {
                    _failures.Add("clipboard: full image/text preview did not keep contain/scroll behavior");
                }

                if (!result.CalculatorHistorySidebarOk)
                {
                    _failures.Add("calculator: Mac-style collapsible history sidebar did not render");
                }

                if (!result.ProviderIconStableOk)
                {
                    _failures.Add("provider icons: state refresh replaced the hovered icon node");
                }

                if (!result.ProviderDragReorderReadyOk)
                {
                    _failures.Add("provider icons: drag reorder affordance was not enabled");
                }

                if (!result.TextInputActivationOk)
                {
                    _failures.Add("text input: panel activation mode did not toggle with the no-activate style");
                }

                if (!result.CalendarMacLayoutOk)
                {
                    _failures.Add("calendar: Mac-style month/detail panes or 42-day dot grid did not render");
                }

                if (!result.CalendarEditorStableOk)
                {
                    _failures.Add("calendar: editor was replaced after the pointer left the day cell");
                }

                if (!result.TimerLayoutOk)
                {
                    _failures.Add("timer: responsive cards overflowed or did not use the available width");
                }

                if (!result.TimerInteractionStableOk)
                {
                    _failures.Add("timer: duration adjustment replaced the active input DOM");
                }

                if (!result.TimerStopwatchOk)
                {
                    _failures.Add("timer: stopwatch controls did not render");
                }

                if (!result.PocketSurfaceRenderedOk
                    || !result.PocketSurfaceSelectionOk
                    || !result.PocketSurfaceDurationOk
                    || !result.PocketSurfacePurposeOk
                    || !result.PocketSurfaceStatePersistedOk
                    || !result.PocketSurfaceStateBoundControlsPersistedOk
                    || !result.PocketSurfaceStateWorkflowInputOk)
                {
                    _failures.Add("pocket surface: declarative Today Focus controls or separated user state did not match the canonical model");
                }

                if (!result.PocketSurfaceApprovalHostOwnedOk)
                {
                    _failures.Add("pocket surface: generated UI attempted to own approval rendering");
                }

                if (!result.PocketSurfaceLayoutMatrixOk)
                {
                    _failures.Add("pocket surface: controls overflowed the Windows S/M/L by text-size layout matrix");
                }

                if (!result.TextSizeScaleReadyOk)
                {
                    _failures.Add("text size: global small/medium/large scaling was not active");
                }

                if (!result.ProviderSwitchOk)
                {
                    _failures.Add($"provider: switch failed from {result.OriginalProvider} to {result.SwitchedProvider}");
                }

                if (!result.ProviderSwitchCleanupAwaitedOk)
                {
                    _failures.Add("provider: switch was requested before the active provider finished flushing pending state");
                }

                if (!result.ProviderSwitchBlockedOnSaveFailureOk)
                {
                    _failures.Add("provider: switch continued after the active provider failed to flush pending state");
                }

                if (!result.ProviderRerenderCleanupAwaitedOk)
                {
                    _failures.Add("provider: rerender replaced the active provider before pending state was flushed");
                }

                if (!result.ProviderRerenderBlockedOnSaveFailureOk)
                {
                    _failures.Add("provider: rerender replaced the active provider after pending state flush failed");
                }

                if (!result.ProviderHostStateFlushOk)
                {
                    _failures.Add("provider: Host state flush was not scoped to the active Pocket App");
                }

                if (!result.PocketSurfaceStateTransitionBoundaryOk)
                {
                    _failures.Add("pocket-surface: state transition did not keep the generated panel inert until release");
                }

                if (!result.PocketSurfaceFailedStateWriteRetriedOk)
                {
                    _failures.Add("pocket-surface: failed state write was not retained for the next flush");
                }

                if (!result.PocketSurfaceWorkflowBlockedOnStateWriteFailureOk)
                {
                    _failures.Add("pocket-surface: workflow started before pending state was durably saved");
                }

                if (!result.ProviderSurfaceIdentityRemountOk)
                {
                    _failures.Add("provider: generated panel did not remount when its package identity changed");
                }

                if (!result.SettingsWriteOk)
                {
                    _failures.Add($"settings: panel size write failed for {result.ProbePanelSize}");
                }
            }

            if (ready && !await _controller.Panel.VerifyBackgroundBridgePostAsync())
            {
                _failures.Add("bridge: background event was not received by WebView2");
            }

            if (ready)
            {
                await new TopHandlePeekVerifier(_controller).RunAsync();
                await new LiquidMotionVerifier(_controller).RunAsync();
                var monitor = _controller.Layouts[0].Monitor.Bounds;
                _controller.SetPointerSimulationForVerify(monitor.Left + 10, monitor.Bottom - 10);
                await VerifyHiddenPanelTimerAsync(withSecondaryView: true);
                await VerifyHiddenPanelTimerAsync(withSecondaryView: false);
                await VerifyLiquidSettingsSurfaceAsync();
            }

            if (_controller.Panel.ProcessFailures.Count > 0)
            {
                _failures.Add("webview process failures: " + string.Join(",", _controller.Panel.ProcessFailures));
            }
        }
        catch (Exception ex)
        {
            _failures.Add(ex.GetType().Name + ": " + ex.Message);
        }

        _controller.ClearPointerSimulationForVerify();
        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine(
                "PASS ui verify: background bridge delivery, hidden-panel timer alert/reopen, stable Controls refresh, source activation and rate actions, responsive Timer cards/input/stopwatch, media fallback, tabbed centered Clipboard split/full preview/trash actions, Calculator history sidebar, declarative PocketSurface renderer with host-owned approval, draggable stable icons, text scaling/input activation, stable Mac-style calendar editor, bridge/provider/settings round-trip");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL ui verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private async Task VerifyLiquidSettingsSurfaceAsync()
    {
        var dataRoot = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "HoverPocket", "LiquidSettings", Guid.NewGuid().ToString("N"));
        var settings = new SettingsWindow(_controller.PanelBridgeController, false, dataRoot, externalIntegrationsEnabled: false);
        try
        {
            settings.Show();
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < deadline)
            {
                if (settings.WebViewForVerify?.CoreWebView2 is not null
                    && await settings.WebViewForVerify.ExecuteScriptAsync("document.querySelectorAll('[data-panel-attachment] button').length === 2") == "true") break;
                await Task.Delay(50);
            }
            var web = settings.WebViewForVerify ?? throw new InvalidOperationException("settings UI failed to initialize");
            await web.ExecuteScriptAsync("""
                window.__liquidSettingsResult = null;
                import('/js/bridge.js').then(async ({request}) => {
                    const wait = async (predicate) => {
                        for (let i = 0; i < 100; i++) {
                            const state = await request('app.getState');
                            if (predicate(state.settings)) return;
                            await new Promise(resolve => setTimeout(resolve, 20));
                        }
                        throw new Error('settings surface readback timed out');
                    };
                    const hiddenEntry = document.querySelector('[data-auto-hide-handle]');
                    hiddenEntry.checked = true; hiddenEntry.dispatchEvent(new Event('change'));
                    await wait(s => s.autoHideTopHandle === true);
                    hiddenEntry.checked = false; hiddenEntry.dispatchEvent(new Event('change'));
                    await wait(s => s.autoHideTopHandle === false);
                    document.querySelectorAll('[data-panel-attachment] button')[1].click();
                    await wait(s => s.panelAttachmentStyle === 'coverMenu');
                    const auto = document.querySelector('[data-automatic-attachment]');
                    auto.checked = true; auto.dispatchEvent(new Event('change'));
                    await wait(s => s.automaticScreenEdgeAttachment === true);
                    document.querySelectorAll('[data-panel-attachment] button')[0].click();
                    await wait(s => s.panelAttachmentStyle === 'preserveMenu' && s.effectivePanelAttachmentStyle === 'coverMenu');
                    auto.checked = false; auto.dispatchEvent(new Event('change'));
                    await wait(s => !s.automaticScreenEdgeAttachment && s.effectivePanelAttachmentStyle === 'preserveMenu');
                    const reduced = document.querySelector('[data-reduce-motion]');
                    reduced.checked = true; reduced.dispatchEvent(new Event('change'));
                    await wait(s => s.reduceMotion === true);
                    reduced.checked = false; reduced.dispatchEvent(new Event('change'));
                    await wait(s => s.reduceMotion === false);
                    window.__liquidSettingsResult = true;
                }).catch(error => { window.__liquidSettingsResult = String(error); });
                """);
            deadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < deadline)
            {
                var result = await web.ExecuteScriptAsync("window.__liquidSettingsResult");
                if (result == "true") { VerifyConsole.WriteLine("PASS liquid Settings WebView2: manual buttons, automatic/manual preservation, Reduce Motion controls, bridge readback"); return; }
                if (result != "null") throw new InvalidOperationException("settings surface: " + result);
                await Task.Delay(50);
            }
            throw new TimeoutException("liquid settings surface verification");
        }
        finally { settings.Close(); }
    }

    private async Task VerifyHiddenPanelTimerAsync(bool withSecondaryView)
    {
        var secondaryViewReceived = false;
        using var secondaryView = withSecondaryView
            ? _controller.PanelBridgeController.Attach(new BridgeDispatcher(json =>
            {
                using var message = JsonDocument.Parse(json);
                if (message.RootElement.TryGetProperty("event", out var eventName)
                    && eventName.GetString() == "timer.alert")
                {
                    secondaryViewReceived = true;
                }

                return Task.CompletedTask;
            }))
            : null;
        var webView = _controller.Panel.WebView!;
        await webView.ExecuteScriptAsync("""
            window.__timerProbeStarted = false;
            window.__timerProbeReceived = false;
            import('/js/bridge.js').then(async ({ request, on }) => {
                const state = await request('timer.getState');
                window.__stopTimerProbeListener = on('timer.alert', ({ alert }) => {
                    if (alert.title === 'Hidden panel verification') {
                        window.__timerProbeReceived = true;
                    }
                });
                await request('timer.start', { preset: {
                    ...state.draftTimer, title: 'Hidden panel verification',
                    durationSeconds: 2, isPomodoro: false, soundEnabled: false
                }});
                window.__timerProbeStarted = true;
            });
            """);
        try
        {
            if (!await WaitForScriptFlagAsync("window.__timerProbeStarted === true"))
            {
                _failures.Add("timer: fixture timer did not start");
                return;
            }

            await _controller.HidePanelForVerifyAsync();
            if (_controller.Panel.IsVisible)
            {
                _failures.Add("timer: panel did not hide before timer expiry");
            }

            if (!await WaitForScriptFlagAsync("window.__timerProbeReceived === true")
                || !_controller.Panel.IsVisible)
            {
                _failures.Add("timer: expiry did not deliver an alert and reopen the hidden panel");
            }

            if (withSecondaryView && !secondaryViewReceived)
            {
                _failures.Add("timer: attached secondary view did not receive the expiry event");
            }
        }
        finally
        {
            await webView.ExecuteScriptAsync("""
                window.__stopTimerProbeListener?.();
                import('/js/bridge.js').then(({ request }) => request('timer.stopAlert'));
                """);
        }
    }

    private async Task<bool> WaitForScriptFlagAsync(string script)
    {
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(5);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (await _controller.Panel.WebView!.ExecuteScriptAsync(script) == "true")
            {
                return true;
            }

            await Task.Delay(50);
        }

        return false;
    }
}
