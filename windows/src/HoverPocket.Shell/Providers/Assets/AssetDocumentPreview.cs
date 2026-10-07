using System.IO.Compression;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace HoverPocket.Shell.Providers.Assets;

internal static class AssetDocumentPreview
{
    internal const int MaximumCharacters = 200_000;
    private const int MaximumBytes = 8 * 1024 * 1024;
    internal static async Task<(string Text, bool Truncated)> ReadAsync(string path, string extension, CancellationToken token)
    {
        if (AssetPreviewFormats.Kind(extension) == "text")
        {
            using var file = File.OpenRead(path);
            var bytes = new byte[Math.Min(file.Length, MaximumBytes)];
            await file.ReadExactlyAsync(bytes, token);
            var count = bytes.Length;
            var data = bytes.AsSpan(0, count);
            string text;
            if (data.StartsWith(new byte[] { 0xff, 0xfe })) text = Encoding.Unicode.GetString(data[2..]);
            else if (data.StartsWith(new byte[] { 0xfe, 0xff })) text = Encoding.BigEndianUnicode.GetString(data[2..]);
            else
            {
                try { text = new UTF8Encoding(false, true).GetString(data); }
                catch (DecoderFallbackException)
                {
                    Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
                    text = Encoding.GetEncoding(932, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetString(data);
                }
            }
            text = text.TrimStart('\ufeff');
            if (text.Contains('\0')) throw new InvalidDataException("バイナリファイルをテキストとして表示できません。原本は保存されています。");
            return (text[..Math.Min(text.Length, MaximumCharacters)], file.Length > count || text.Length > MaximumCharacters);
        }
        if (extension is "docx" or "xlsx" or "pptx" or "odt" or "ods" or "odp" or "epub")
        {
            if (new FileInfo(path).Length > 64 * 1024 * 1024) throw new InvalidDataException("この文書は表示の容量上限を超えています。原本は保存されています。");
            using var zip = ZipFile.OpenRead(path);
            var output = new StringBuilder(); var usedBytes = 0L; var truncated = false;
            var strings = Array.Empty<string>();
            if (extension == "xlsx" && zip.GetEntry("xl/sharedStrings.xml") is { } shared)
                strings = ReadXml(shared).Descendants().Where(x => x.Name.LocalName == "si").Select(x => string.Concat(x.Descendants().Where(v => v.Name.LocalName == "t").Select(v => v.Value))).ToArray();
            var entries = zip.Entries.Where(entry => extension switch
            {
                "docx" => entry.FullName == "word/document.xml",
                "xlsx" => entry.FullName.StartsWith("xl/worksheets/sheet", StringComparison.Ordinal) && entry.FullName.EndsWith(".xml", StringComparison.Ordinal),
                "pptx" => entry.FullName.StartsWith("ppt/slides/slide", StringComparison.Ordinal) && entry.FullName.EndsWith(".xml", StringComparison.Ordinal),
                "epub" => entry.FullName.EndsWith(".xhtml", StringComparison.Ordinal) || entry.FullName.EndsWith(".html", StringComparison.Ordinal),
                _ => entry.FullName == "content.xml"
            }).OrderBy(entry => entry.FullName, StringComparer.Ordinal).Take(201).ToArray();
            foreach (var entry in entries.Take(200))
            {
                token.ThrowIfCancellationRequested(); usedBytes += entry.Length;
                if (usedBytes > MaximumBytes) { truncated = true; break; }
                var xml = ReadXml(entry);
                if (extension is "xlsx" or "pptx") output.AppendLine($"── {entry.Name} ──");
                if (extension == "xlsx")
                {
                    foreach (var row in xml.Descendants().Where(x => x.Name.LocalName == "row"))
                        output.AppendLine(string.Join("\t", row.Elements().Where(x => x.Name.LocalName == "c").Select(cell =>
                        {
                            var value = cell.Elements().FirstOrDefault(x => x.Name.LocalName == "v")?.Value ?? string.Concat(cell.Descendants().Where(x => x.Name.LocalName == "t").Select(x => x.Value));
                            return (string?)cell.Attribute("t") == "s" && int.TryParse(value, out var index) && index >= 0 && index < strings.Length ? strings[index] : value;
                        })));
                }
                else
                {
                    var paragraphs = xml.Descendants().Where(x => x.Name.LocalName is "p" or "h" or "li");
                    foreach (var paragraph in paragraphs)
                    {
                        var words = paragraph.Descendants().Where(x => x.Name.LocalName == "t").ToArray();
                        output.AppendLine(words.Length > 0 ? string.Concat(words.Select(x => x.Value)) : paragraph.Value);
                    }
                }
                if (output.Length >= MaximumCharacters) { truncated = true; break; }
            }
            var text = output.ToString();
            if (string.IsNullOrWhiteSpace(text)) throw new InvalidDataException("表示できる本文がありません。保護された文書や図表中心の文書は外部アプリで開いてください。");
            return (text[..Math.Min(text.Length, MaximumCharacters)], truncated || entries.Length > 200);
        }
        if (extension == "rtf")
        {
            if (new FileInfo(path).Length > MaximumBytes) throw new InvalidDataException("この文書は表示の容量上限を超えています。");
            var ready = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            var thread = new Thread(() => { try { using var box = new System.Windows.Forms.RichTextBox(); box.LoadFile(path); ready.SetResult(box.Text); } catch (Exception ex) { ready.SetException(ex); } });
            thread.SetApartmentState(ApartmentState.STA); thread.IsBackground = true; thread.Start();
            var text = await ready.Task.WaitAsync(token);
            return (text[..Math.Min(text.Length, MaximumCharacters)], text.Length > MaximumCharacters);
        }
        throw new InvalidDataException("この文書の本文表示には外部アプリが必要です。「外部アプリで開く」から確認できます。原本は保存されています。");
    }
    private static XDocument ReadXml(ZipArchiveEntry entry)
    {
        if (entry.Length > MaximumBytes) throw new InvalidDataException("文書の展開サイズが表示の上限を超えています。");
        using var stream = entry.Open();
        using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = MaximumBytes });
        return XDocument.Load(reader);
    }
}
