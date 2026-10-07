using System.Text.Json;

namespace HoverPocket.Shell.Voice;

internal sealed record ChatModelChoice(string Model, string DisplayName, string DefaultReasoningEffort, string[] Efforts);

internal sealed partial class CodexChatCoordinator
{
    internal void RestoreOptions(string? model, string? effort)
    {
        Model = model is { Length: > 0 and <= 160 } && model.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.') ? model : null;
        Effort = effort is "none" or "minimal" or "low" or "medium" or "high" or "xhigh" or "max" or "ultra" ? effort : null;
    }

    internal async Task LoadModelsAsync(CancellationToken token)
    {
        if (!await _gate.WaitAsync(0, token)) throw new InvalidOperationException("chat_busy");
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, _lifetime.Token);
            token = linked.Token;
            await ConnectAsync(token);
            var choices = new List<ChatModelChoice>();
            string? cursor = null;
            for (var page = 0; page < 8; page++)
            {
                var result = await _client!.SendRequestAsync("model/list", JsonSerializer.SerializeToElement(new { cursor, limit = 100 }), token);
                foreach (var item in result.GetProperty("data").EnumerateArray())
                {
                    if (item.TryGetProperty("hidden", out var hidden) && hidden.ValueKind == JsonValueKind.True) continue;
                    var model = item.GetProperty("model").GetString();
                    if (string.IsNullOrWhiteSpace(model) || model.Length > 160) continue;
                    var efforts = item.GetProperty("supportedReasoningEfforts").EnumerateArray().Select(e => e.GetProperty("reasoningEffort").GetString()!).ToArray();
                    choices.Add(new(model, item.GetProperty("displayName").GetString() ?? model, item.GetProperty("defaultReasoningEffort").GetString() ?? "medium", efforts));
                }
                cursor = result.TryGetProperty("nextCursor", out var next) && next.ValueKind == JsonValueKind.String ? next.GetString() : null;
                if (cursor is null) break;
            }
            Models = choices.DistinctBy(c => c.Model).ToArray();
            if (Models.Count == 0) throw new CodexAppServerProtocolException("chat_models_unavailable");
            _error = null;
        }
        catch (OperationCanceledException) { await DisconnectAsync(); }
        catch (Exception ex) when (ex is CodexAppServerProtocolException or JsonException or IOException)
        {
            _error = ex is CodexAppServerProtocolException protocol ? protocol.Code : "chat_models_unavailable";
            await DisconnectAsync();
        }
        finally { _gate.Release(); Publish(); }
    }

    internal void Configure(string model, string effort)
    {
        lock (_sync)
        {
            if (_busy) throw new InvalidOperationException("chat_busy");
            if (model.Length == 0 && effort.Length == 0) { Model = null; Effort = null; }
            else
            {
            var choice = Models.SingleOrDefault(c => c.Model == model);
            if (choice is null || !choice.Efforts.Contains(effort)) throw new ArgumentException("chat_model_invalid");
            Model = model; Effort = effort;
            }
        }
        Publish();
    }
}
