using HoverPocket.Shell.Windows;

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

            if (_controller.Panel.ProcessFailures.Count > 0)
            {
                _failures.Add("webview process failures: " + string.Join(",", _controller.Panel.ProcessFailures));
            }
        }
        catch (Exception ex)
        {
            _failures.Add(ex.GetType().Name + ": " + ex.Message);
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine(
                "PASS ui verify: stable Controls refresh, source activation and rate actions, responsive Timer cards/input/stopwatch, media fallback, tabbed centered Clipboard split/full preview/trash actions, Calculator history sidebar, declarative PocketSurface renderer with host-owned approval, draggable stable icons, text scaling/input activation, stable Mac-style calendar editor, bridge/provider/settings round-trip");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL ui verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }
}
