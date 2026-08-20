using System.Windows.Media;
using System.Windows.Threading;
using HoverPocket.Shell.Capabilities;
using Wpf = System.Windows;
using WpfAutomationProperties = System.Windows.Automation.AutomationProperties;
using WpfControls = System.Windows.Controls;

namespace HoverPocket.Shell.Voice;

internal sealed class VoiceTimerApprovalCoordinator
{
    internal const int MaximumPromptsPerWindow = 3;
    internal static readonly TimeSpan PromptWindow = TimeSpan.FromMinutes(1);

    private readonly object _sync = new();
    private readonly Queue<DateTimeOffset> _promptStarts = new();
    private readonly Func<DateTimeOffset> _now;
    private bool _active;

    public VoiceTimerApprovalCoordinator(Func<DateTimeOffset>? now = null)
    {
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public async Task<bool> RequestAsync(
        VoiceTimerApprovalRequest request,
        Func<VoiceTimerApprovalRequest, CancellationToken, Task<bool>> present,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(present);
        cancellationToken.ThrowIfCancellationRequested();
        lock (_sync)
        {
            var now = _now();
            while (_promptStarts.TryPeek(out var started)
                && now - started >= PromptWindow)
            {
                _promptStarts.Dequeue();
            }
            if (_active || _promptStarts.Count >= MaximumPromptsPerWindow)
            {
                throw new CapabilityBrokerException(
                    "CAPABILITY_RATE_LIMITED",
                    "voice_timer_approval");
            }
            _active = true;
            _promptStarts.Enqueue(now);
        }

        try
        {
            return await present(request, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (_sync)
            {
                _active = false;
            }
        }
    }
}

internal static class VoiceTimerApprovalDialog
{
    public static async Task<bool> ShowAsync(
        Wpf.Window owner,
        VoiceTimerApprovalRequest request,
        bool english,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var dispatcher = owner.Dispatcher;
        if (dispatcher.HasShutdownStarted)
        {
            return false;
        }

        Wpf.Window? dialog = null;
        var operation = dispatcher.InvokeAsync(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!owner.IsVisible)
            {
                return false;
            }
            dialog = Build(owner, request, english);
            return dialog.ShowDialog() == true;
        });
        try
        {
            return await operation.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            _ = operation.Abort();
            try
            {
                await dispatcher.InvokeAsync(() =>
                {
                    if (dialog?.IsVisible == true)
                    {
                        dialog.Close();
                    }
                }).Task.ConfigureAwait(false);
            }
            catch (TaskCanceledException)
            {
            }
            throw;
        }
    }

    private static Wpf.Window Build(
        Wpf.Window owner,
        VoiceTimerApprovalRequest request,
        bool english)
    {
        var duration = request.DurationSeconds % 60 == 0
            ? english
                ? $"{request.DurationSeconds / 60} minutes"
                : $"{request.DurationSeconds / 60}分"
            : english
                ? $"{request.DurationSeconds} seconds"
                : $"{request.DurationSeconds}秒";
        var dialog = new Wpf.Window
        {
            Owner = owner,
            Title = english ? "Approve Timer" : "Timerを承認",
            WindowStartupLocation = Wpf.WindowStartupLocation.CenterOwner,
            WindowStyle = Wpf.WindowStyle.ToolWindow,
            ResizeMode = Wpf.ResizeMode.NoResize,
            ShowInTaskbar = false,
            SizeToContent = Wpf.SizeToContent.WidthAndHeight,
            MinWidth = 420,
            MaxWidth = 560,
            Background = new SolidColorBrush(Color.FromRgb(24, 24, 24)),
            Foreground = Brushes.White
        };
        var content = new WpfControls.StackPanel
        {
            Margin = new Wpf.Thickness(24),
            Orientation = WpfControls.Orientation.Vertical
        };
        content.Children.Add(new WpfControls.TextBlock
        {
            Text = english
                ? $"Timer: {request.Title}\nDuration: {duration}\n\nStart this timer?"
                : $"Timer: {request.Title}\n時間: {duration}\n\nこのタイマーを開始しますか？",
            TextWrapping = Wpf.TextWrapping.Wrap,
            FontSize = 16,
            MaxWidth = 500
        });
        var actions = new WpfControls.StackPanel
        {
            Margin = new Wpf.Thickness(0, 20, 0, 0),
            HorizontalAlignment = Wpf.HorizontalAlignment.Right,
            Orientation = WpfControls.Orientation.Horizontal
        };
        var reject = new WpfControls.Button
        {
            Content = english ? "Cancel" : "キャンセル",
            IsCancel = true,
            IsDefault = true,
            MinWidth = 104,
            Padding = new Wpf.Thickness(14, 8, 14, 8)
        };
        WpfAutomationProperties.SetName(reject, english ? "Reject timer" : "Timerを拒否");
        var approve = new WpfControls.Button
        {
            Content = english ? "Start" : "開始",
            MinWidth = 104,
            Margin = new Wpf.Thickness(12, 0, 0, 0),
            Padding = new Wpf.Thickness(14, 8, 14, 8)
        };
        WpfAutomationProperties.SetName(approve, english ? "Approve timer" : "Timerを承認");
        approve.Click += (_, _) => dialog.DialogResult = true;
        reject.Click += (_, _) => dialog.DialogResult = false;
        actions.Children.Add(reject);
        actions.Children.Add(approve);
        content.Children.Add(actions);
        dialog.Content = content;
        return dialog;
    }
}
