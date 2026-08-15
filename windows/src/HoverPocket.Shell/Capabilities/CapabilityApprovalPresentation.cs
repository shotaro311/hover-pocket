using System.Globalization;
using System.Text;
using HoverPocket.Shell.Providers.Sticky;

namespace HoverPocket.Shell.Capabilities;

internal enum CapabilityApprovalTargetState
{
    Present,
    Missing
}

// Host-memory-only. Do not serialize this into contracts, audit logs, receipts,
// generated surfaces, or agent transcripts.
internal sealed record CapabilityApprovalPresentation(
    string RequestId,
    string PlanDigest,
    string StepId,
    string ArgumentDigest,
    string ActionKey,
    string TargetKind,
    string TargetDisplayKey,
    string? TargetDisplayLabel,
    CapabilityApprovalTargetState TargetState,
    bool Destructive,
    bool RollbackAvailable);

internal interface ICapabilityApprovalPresentationResolver
{
    IReadOnlyList<CapabilityApprovalPresentation> Resolve(
        CapabilityExecutionPlan plan,
        IReadOnlyList<PocketCapabilityDescriptor> descriptors,
        CapabilityApprovalRequest request);
}

internal sealed class EmptyCapabilityApprovalPresentationResolver : ICapabilityApprovalPresentationResolver
{
    public IReadOnlyList<CapabilityApprovalPresentation> Resolve(
        CapabilityExecutionPlan plan,
        IReadOnlyList<PocketCapabilityDescriptor> descriptors,
        CapabilityApprovalRequest request) => [];
}

internal sealed class HostCapabilityApprovalPresentationResolver(StickyNotesStore stickyStore)
    : ICapabilityApprovalPresentationResolver
{
    private const int MaximumDisplayRunes = 80;

    public IReadOnlyList<CapabilityApprovalPresentation> Resolve(
        CapabilityExecutionPlan plan,
        IReadOnlyList<PocketCapabilityDescriptor> descriptors,
        CapabilityApprovalRequest request)
    {
        var presentations = new List<CapabilityApprovalPresentation>();
        foreach (var pair in plan.Steps.Zip(descriptors))
        {
            if (pair.Second.Key != CapabilityIds.StickyDelete)
            {
                continue;
            }
            var rawId = CapabilityJson.RequiredString(pair.First.Arguments, "noteId", 128);
            var effect = request.Effects.SingleOrDefault(item => item.StepId == pair.First.Id);
            if (!Guid.TryParse(rawId, out var noteId) || effect is null)
            {
                throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "approval_target");
            }
            var note = stickyStore.GetNote(noteId);
            presentations.Add(new CapabilityApprovalPresentation(
                request.Id,
                request.PlanDigest,
                pair.First.Id,
                effect.ArgumentDigest,
                "approval.sticky.note.delete",
                "sticky_note",
                note is null ? "approval.target.sticky_note.missing" : "approval.target.sticky_note",
                note is null ? null : SanitizedDisplayLabel(note.Title),
                note is null ? CapabilityApprovalTargetState.Missing : CapabilityApprovalTargetState.Present,
                pair.Second.Effect == CapabilityEffect.DestructiveSensitive,
                pair.Second.RollbackAvailable));
        }
        return presentations;
    }

    internal static string? SanitizedDisplayLabel(string value)
    {
        var result = new StringBuilder();
        var runeCount = 0;
        var pendingSpace = false;
        foreach (var rune in value.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune))
            {
                pendingSpace = result.Length > 0;
                continue;
            }
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.Control or UnicodeCategory.Format)
            {
                continue;
            }
            if (pendingSpace && runeCount < MaximumDisplayRunes)
            {
                result.Append(' ');
                runeCount++;
                pendingSpace = false;
            }
            if (runeCount >= MaximumDisplayRunes)
            {
                break;
            }
            result.Append(rune.ToString());
            runeCount++;
        }
        var sanitized = result.ToString().Trim();
        return sanitized.Length == 0 ? null : sanitized;
    }
}
