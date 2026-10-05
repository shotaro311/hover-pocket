using System.Text.Json;

namespace HoverPocket.Shell.Voice;

internal sealed record CodexChatHistoryEntry(string ThreadId, DateTimeOffset CreatedAt, string ToolDigest)
{
    public override string ToString() => CreatedAt.ToLocalTime().ToString("MM/dd HH:mm");
}

// App-server owns the conversation. This index only identifies threads created by this UI.
internal sealed class CodexChatHistory(string root)
{
    private string FilePath => Path.Combine(root, "chat-history.json");
    public IReadOnlyList<CodexChatHistoryEntry> Read()
    {
        if (!File.Exists(FilePath)) return [];
        if (new FileInfo(FilePath).Length > 64 * 1024) throw new IOException("chat_history_invalid");
        CodexChatHistoryEntry[] entries;
        try { entries = JsonSerializer.Deserialize<CodexChatHistoryEntry[]>(File.ReadAllText(FilePath)) ?? []; }
        catch (JsonException exception) { throw new IOException("chat_history_invalid", exception); }
        if (entries.Length > 40 || entries.Any(e => e is null || !IsId(e.ThreadId) || e.ToolDigest is not { Length: 64 } || !e.ToolDigest.All(char.IsAsciiHexDigit))
            || entries.Select(e => e.ThreadId).Distinct().Count() != entries.Length) throw new IOException("chat_history_invalid");
        return entries;
    }

    public void Add(CodexChatHistoryEntry entry)
    {
        var entries = new[] { entry }.Concat(Read().Where(e => e.ThreadId != entry.ThreadId)).Take(40).ToArray();
        Directory.CreateDirectory(root);
        var temp = FilePath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(entries));
        File.Move(temp, FilePath, overwrite: true);
    }

    internal static bool IsId(string? value) => !string.IsNullOrWhiteSpace(value) && value.Length <= 160
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
}
