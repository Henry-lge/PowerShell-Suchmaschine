using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Text.RegularExpressions;

namespace FileSearcherApp
{
    public sealed record SearchHit(
        string Path, string FileName, string Extension,
        DateTime LastWriteUtc, string Snippet, double Score, string MatchedIn = "")
    {
        //Text für den Tooltip: Leerzeichen und Zeilenumbrüche aus dem Snippet werden zusammengezogen
        public string Preview =>
        string.IsNullOrWhiteSpace(Snippet)
            ? "Keine Vorschau verfügbar."
            : Regex.Replace(Snippet, @"\s+", " ").Trim();
        
        //Änderungsdatum für Tooltip: in Lokalzeit, für den Tooltip
        public string LastWriteText => LastWriteUtc.ToLocalTime().ToString("g");
        public override string ToString() =>
        string.IsNullOrEmpty(MatchedIn) ? $"{FileName} — {Path}"
                                        : $"[{MatchedIn}] {FileName} — {Path}";
    }

    public sealed class SearchException : Exception
    {
        public SearchException(string message) : base(message) { }
    }

    public interface ISearchService
    {
        Task<IReadOnlyList<SearchHit>> SearchAsync(
         string query, int limit = 100, string? extension = null,
            string mode = "both", CancellationToken ct = default);
    }

    public sealed class PowerShellSearchService : ISearchService
    {
        private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
        private static readonly UTF8Encoding Utf8 = new(false);

        private readonly string _scriptPath;
        private readonly string _databasePath;

        public PowerShellSearchService(string scriptPath, string databasePath)
        {
            _scriptPath = scriptPath;
            _databasePath = databasePath;
        }

        public async Task<IReadOnlyList<SearchHit>> SearchAsync(
            string query, int limit = 100, string? extension = null, string mode = "both", CancellationToken ct = default)
        {
            var psi = new ProcessStartInfo("pwsh")
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardInputEncoding = Utf8,
                StandardOutputEncoding = Utf8,
                StandardErrorEncoding = Utf8,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-NonInteractive");
            if (OperatingSystem.IsWindows())
            {
                psi.ArgumentList.Add("-ExecutionPolicy");
                psi.ArgumentList.Add("Bypass");
            }
            psi.ArgumentList.Add("-File");
            psi.ArgumentList.Add(_scriptPath);
            psi.ArgumentList.Add("-DatabasePath");
            psi.ArgumentList.Add(_databasePath);

            Process proc;
            try
            {
                proc = Process.Start(psi) ?? throw new SearchException("pwsh konnte nicht gestartet werden.");
            }
            catch (Win32Exception)
            {
                throw new SearchException("pwsh (PowerShell 7.2+) wurde nicht gefunden.");
            }

            using (proc)
            using (ct.Register(() => { try { proc.Kill(true); } catch { } }))
            {
                var normalizedMode = mode.Trim().ToLowerInvariant();

if (normalizedMode is not ("filename" or "content" or "both"))
    throw new SearchException($"Ungültiger Suchmodus: {mode}");

var request = JsonSerializer.Serialize(
    new
    {
        query,
        limit,
        extension,
        prefix = true,
        mode = normalizedMode
    },
    Json);
                await proc.StandardInput.WriteAsync(request);
                proc.StandardInput.Close();

                var stdoutTask = proc.StandardOutput.ReadToEndAsync();
                var stderrTask = proc.StandardError.ReadToEndAsync();
                await proc.WaitForExitAsync(ct);
                var stdout = await stdoutTask;
                var stderr = await stderrTask;

                SearchResponse? response;
                try
                {
                    response = JsonSerializer.Deserialize<SearchResponse>(stdout, Json);
                }
                catch (JsonException)
                {
                    throw new SearchException($"Ungültige Antwort von PowerShell: {stderr}{stdout}".Trim());
                }

                if (response is not { Ok: true })
                    throw new SearchException(response?.Error ?? "Unbekannter Fehler");
                return response.Results ?? new List<SearchHit>();
            }
        }

        private sealed record SearchResponse(bool Ok, string? Error, List<SearchHit>? Results);
    }

    public static class SearchBridge
    {
        public static ISearchService CreateDefault()
        {
            var script = FindUp("Invoke-GuiSearch.ps1");
            var root = Path.GetDirectoryName(script)!;
            var db = Path.Combine(root, "data", "index.sqlite3");

            return new PowerShellSearchService(script, db);
        }

        private static string FindUp(string fileName)
        {
            for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            {
                var path = Path.Combine(dir.FullName, fileName);
                if (File.Exists(path)) return path;
            }
            throw new FileNotFoundException($"{fileName} wurde oberhalb von {AppContext.BaseDirectory} nicht gefunden.");
        }
    }
}