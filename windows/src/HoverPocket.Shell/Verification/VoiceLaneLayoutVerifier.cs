using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;

namespace HoverPocket.Shell.Verification;

internal sealed class VoiceLaneLayoutVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        VerifyCatalogMetrics();
        VerifyDisplayLayoutGeometry();
        VerifySmallDisplayClamp();

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine(
                "PASS voice-lane-layout verify: disabled/compact/expanded metrics, display geometry, small-screen clamp");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL voice-lane-layout verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyCatalogMetrics()
    {
        var cases = new[]
        {
            new LayoutCase(PanelSize.Small, VoiceLaneLayoutState.Disabled, 520, 372, 0),
            new LayoutCase(PanelSize.Medium, VoiceLaneLayoutState.Disabled, 600, 430, 0),
            new LayoutCase(PanelSize.Large, VoiceLaneLayoutState.Disabled, 680, 488, 0),
            new LayoutCase(PanelSize.Small, VoiceLaneLayoutState.Compact, 520, 372, 64),
            new LayoutCase(PanelSize.Medium, VoiceLaneLayoutState.Compact, 600, 430, 64),
            new LayoutCase(PanelSize.Large, VoiceLaneLayoutState.Compact, 680, 488, 64),
            new LayoutCase(PanelSize.Small, VoiceLaneLayoutState.Expanded, 520, 372, 190),
            new LayoutCase(PanelSize.Medium, VoiceLaneLayoutState.Expanded, 600, 430, 220),
            new LayoutCase(PanelSize.Large, VoiceLaneLayoutState.Expanded, 680, 488, 250)
        };

        foreach (var testCase in cases)
        {
            var metrics = PanelSizeCatalog.Get(testCase.PanelSize, testCase.Layout);
            CheckEqual(testCase.Width, metrics.Width, $"{testCase} width");
            CheckEqual(testCase.ProviderHeight, metrics.ProviderHeight, $"{testCase} provider height");
            CheckEqual(testCase.LaneHeight, metrics.AiLaneHeight, $"{testCase} lane height");
            CheckEqual(
                testCase.ProviderHeight + testCase.LaneHeight,
                metrics.TotalHeight,
                $"{testCase} total height");
        }

        var stableDefault = PanelSizeCatalog.Get(PanelSize.Medium);
        CheckEqual(0, stableDefault.AiLaneHeight, "default caller lane height");
        CheckEqual(430, stableDefault.TotalHeight, "default caller total height");
    }

    private void VerifyDisplayLayoutGeometry()
    {
        var monitor = CreateMonitor(new PhysicalRect(0, 0, 1920, 1080), dpiX: 96, dpiY: 96);
        var service = new DisplayLayoutService();

        foreach (var state in new[]
        {
            VoiceLaneLayoutState.Disabled,
            VoiceLaneLayoutState.Compact,
            VoiceLaneLayoutState.Expanded
        })
        {
            var layout = service.CreateLayout(
                monitor,
                PanelSize.Medium,
                voiceLaneLayout: state);
            var metrics = PanelSizeCatalog.Get(PanelSize.Medium, state);
            CheckEqual(600, layout.PanelTarget.PhysicalRect.Width, $"{state.Mode} physical width");
            CheckEqual(
                (int)metrics.TotalHeight,
                layout.PanelTarget.PhysicalRect.Height,
                $"{state.Mode} physical height");
            CheckEqual(
                layout.AccessSurface.PhysicalRect.Bottom,
                layout.PanelTarget.PhysicalRect.Top,
                $"{state.Mode} panel top");
            CheckEqual(
                layout.PanelTarget.PhysicalRect.Top,
                layout.PanelCollapsed.PhysicalRect.Top,
                $"{state.Mode} collapsed top");
        }

        var disabled = service.CreateLayout(
            monitor,
            PanelSize.Medium,
            voiceLaneLayout: VoiceLaneLayoutState.Disabled);
        var compact = service.CreateLayout(
            monitor,
            PanelSize.Medium,
            voiceLaneLayout: VoiceLaneLayoutState.Compact);
        var expanded = service.CreateLayout(
            monitor,
            PanelSize.Medium,
            voiceLaneLayout: VoiceLaneLayoutState.Expanded);
        CheckEqual(
            64,
            compact.PanelTarget.PhysicalRect.Height - disabled.PanelTarget.PhysicalRect.Height,
            "compact height delta");
        CheckEqual(
            220,
            expanded.PanelTarget.PhysicalRect.Height - disabled.PanelTarget.PhysicalRect.Height,
            "expanded height delta");
    }

    private void VerifySmallDisplayClamp()
    {
        var monitor = CreateMonitor(new PhysicalRect(0, 0, 640, 480), dpiX: 144, dpiY: 144);
        var service = new DisplayLayoutService();
        var layout = service.CreateLayout(
            monitor,
            PanelSize.Large,
            voiceLaneLayout: VoiceLaneLayoutState.Expanded);

        if (!monitor.Bounds.Contains(
                layout.PanelTarget.PhysicalRect.Left,
                layout.PanelTarget.PhysicalRect.Top)
            || layout.PanelTarget.PhysicalRect.Right > monitor.Bounds.Right
            || layout.PanelTarget.PhysicalRect.Bottom > monitor.Bounds.Bottom)
        {
            _failures.Add("expanded layout escaped a small high-DPI display");
        }

        CheckEqual(
            monitor.Bounds.Height - layout.AccessSurface.PhysicalRect.Height,
            layout.PanelTarget.PhysicalRect.Height,
            "small display height clamp");
    }

    private static DisplayMonitor CreateMonitor(
        PhysicalRect bounds,
        uint dpiX,
        uint dpiY)
    {
        return new DisplayMonitor(
            "voice-lane-layout-verify",
            "Voice Lane Verify Display",
            IntPtr.Zero,
            bounds,
            bounds,
            true,
            dpiX,
            dpiY);
    }

    private void CheckEqual(double expected, double actual, string label)
    {
        if (Math.Abs(expected - actual) > 0.001)
        {
            _failures.Add($"{label}: expected {expected}, actual {actual}");
        }
    }

    private void CheckEqual(int expected, int actual, string label)
    {
        if (expected != actual)
        {
            _failures.Add($"{label}: expected {expected}, actual {actual}");
        }
    }

    private sealed record LayoutCase(
        PanelSize PanelSize,
        VoiceLaneLayoutState Layout,
        double Width,
        double ProviderHeight,
        double LaneHeight);
}
