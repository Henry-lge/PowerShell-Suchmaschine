using System;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace FileSearcherApp
{
    public class CrawlerService
    {
        private Process? _activeProcess;

        public bool IsScanning { get; private set; }
        public string CurrentStatus { get; private set; } = "Bereit";
        public double CurrentProgress { get; private set; } = 0;
        public bool IsIndeterminate { get; private set; } = true;

        public event Action<string>? StatusChanged;
        public event Action<double, bool>? ProgressChanged;
        public event Action? ScanCompleted;

        // =========================================================================
        // NEU: Datenbank-Pfad & Prüfung auf bestehenden Index inkl. Zeitstempel
        // =========================================================================

        /// <summary>
        /// Ermittelt das Hauptverzeichnis des Projekts.
        /// </summary>
        public string GetProjectRoot()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;

            string? currentDir = baseDir;
            while (currentDir != null &&
                   !File.Exists(Path.Combine(currentDir, "PowerShell-Suchmaschine.sln")) &&
                   Path.GetFileName(currentDir) != "PowerShell-Suchmaschine")
            {
                var parent = Directory.GetParent(currentDir);
                if (parent == null) break;
                currentDir = parent.FullName;
            }

            return currentDir ?? Path.GetFullPath(Path.Combine(baseDir, "../../../"));
        }

        /// <summary>
        /// Gibt den Pfad zur Standard-SQLite-Datenbank (data/index.sqlite3) zurück.
        /// </summary>
        public string GetDatabasePath()
        {
            return Path.Combine(GetProjectRoot(), "data", "index.sqlite3");
        }

        /// <summary>
        /// Prüft, ob bereits eine nicht-leere Datenbank existiert und liefert das Datum der letzten Aktualisierung.
        /// </summary>
        public bool TryGetExistingDatabaseLastWriteTime(out DateTime lastUpdated)
        {
            lastUpdated = DateTime.MinValue;
            string dbPath = GetDatabasePath();

            if (!File.Exists(dbPath))
            {
                return false;
            }

            var dbInfo = new FileInfo(dbPath);
            if (dbInfo.Length == 0)
            {
                return false;
            }

            lastUpdated = dbInfo.LastWriteTime;

            // Im SQLite-WAL-Modus liegen die neuesten Änderungen oft in der .sqlite3-wal Datei
            string walPath = dbPath + "-wal";
            if (File.Exists(walPath))
            {
                DateTime walWriteTime = File.GetLastWriteTime(walPath);
                if (walWriteTime > lastUpdated)
                {
                    lastUpdated = walWriteTime;
                }
            }

            return true;
        }

        /// <summary>
        /// Setzt den Status, wenn der Nutzer auf einen erneuten Scan verzichtet.
        /// </summary>
        public void SkipInitialScan(DateTime lastUpdated)
        {
            IsScanning = false;
            UpdateProgress(100, false);
            UpdateStatus($"Bestehender Index aktiv (Letzte Aktualisierung: {lastUpdated:dd.MM.yyyy 'um' HH:mm 'Uhr'}).");
        }

        // =========================================================================

        public void StartBackgroundScan()
        {
            if (IsScanning) return;

            IsScanning = true;
            UpdateStatus("Hintergrund-Scan wird gestartet...");
            UpdateProgress(0, true);

            _ = Task.Run(() => RunCrawlerProcess());
        }

        public void StopScan()
        {
            try
            {
                if (_activeProcess != null && !_activeProcess.HasExited)
                {
                    _activeProcess.Kill(entireProcessTree: true);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Fehler beim Beenden des Crawler-Prozesses: {ex.Message}");
            }
        }

        private void RunCrawlerProcess()
        {
            var phase2Stopwatch = new Stopwatch();

            try
            {
                // <--- GEÄNDERT: Nutzt jetzt die gemeinsame Hilfsmethode GetProjectRoot()
                string projectRoot = GetProjectRoot();
                string crawlerModulePath = Path.Combine(projectRoot, "src", "Crawler", "Crawler.psm1");

                if (!File.Exists(crawlerModulePath))
                {
                    UpdateStatus($"Fehler: Modul nicht gefunden ({crawlerModulePath})");
                    Console.WriteLine($"[FEHLER] Modul nicht gefunden unter: {crawlerModulePath}");
                    return;
                }

                string scanFolder = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                string escapedCrawlerModulePath = crawlerModulePath.Replace("'", "''");
                string escapedScanFolder = scanFolder.Replace("'", "''");

                string psCommand = $@"
                    using module '{escapedCrawlerModulePath}'; 
                    $c = [Crawler]::new(); 
                    $c.ProgressOutput = $true; 
                    $c.ProgressInterval = 25; 
                    try {{ 
                        $c.ScanFolder('{escapedScanFolder}') 
                    }} 
                    finally {{ 
                        $c.Dispose() 
                    }}";

                var startInfo = new ProcessStartInfo
                {
                    FileName = "pwsh",
                    Arguments = $"-NoProfile -NonInteractive -Command \"{psCommand}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                using var process = new Process { StartInfo = startInfo };
                _activeProcess = process;

                process.OutputDataReceived += (sender, e) =>
                {
                    if (string.IsNullOrWhiteSpace(e.Data)) return;

                    if (e.Data.StartsWith("Scanned:"))
                    {
                        phase2Stopwatch.Restart();

                        var match = Regex.Match(e.Data, @"Scanned:\s*(\d+)");
                        if (match.Success)
                        {
                            string count = match.Groups[1].Value;
                            UpdateProgress(0, true);
                            UpdateStatus($"Dateien werden indiziert... ({count} verarbeitet – Suche bereits aktiv)");
                        }
                    }
                    else if (e.Data.StartsWith("Read:"))
                    {
                        var match = Regex.Match(e.Data, @"Read:\s*(\d+)\s*of\s*(\d+)");
                        if (match.Success &&
                            double.TryParse(match.Groups[1].Value, out double done) &&
                            double.TryParse(match.Groups[2].Value, out double total) &&
                            total > 0)
                        {
                            double percent = (done / total) * 100;
                            UpdateProgress(percent, false);

                            string etaText = CalculateEtaText(done, total, phase2Stopwatch.Elapsed);
                            UpdateStatus($"Dateiinhalte werden gelesen... ({done}/{total}) – Restzeit: {etaText}");
                        }
                    }
                };

                phase2Stopwatch.Start();

                process.Start();
                process.BeginOutputReadLine();
                process.WaitForExit();

                phase2Stopwatch.Stop();

                UpdateProgress(100, false);
                UpdateStatus("Index ist vollständig auf dem neuesten Stand.");
            }
            catch (Exception ex)
            {
                UpdateStatus($"Hintergrund-Scan fehlgeschlagen: {ex.Message}");
                Console.WriteLine($"Prozess-Fehler: {ex.Message}");
            }
            finally
            {
                _activeProcess = null;
                IsScanning = false;
                ScanCompleted?.Invoke();
            }
        }

        private static string CalculateEtaText(double done, double total, TimeSpan elapsed)
        {
            if (done <= 0 || elapsed.TotalSeconds < 1.0)
            {
                return "wird berechnet...";
            }

            double remainingItems = total - done;
            if (remainingItems <= 0)
            {
                return "wenige Sekunden";
            }

            double secondsPerItem = elapsed.TotalSeconds / done;
            TimeSpan estimatedRemaining = TimeSpan.FromSeconds(secondsPerItem * remainingItems);

            return $"ca. {FormatDuration(estimatedRemaining)}";
        }

        private static string FormatDuration(TimeSpan duration)
        {
            if (duration.TotalSeconds < 5)
            {
                return "wenige Sekunden";
            }
            if (duration.TotalMinutes < 1)
            {
                return $"{Math.Ceiling(duration.TotalSeconds)} Sek.";
            }
            if (duration.TotalHours < 1)
            {
                return $"{duration.Minutes} Min. {duration.Seconds} Sek.";
            }

            return $"{(int)duration.TotalHours} Std. {duration.Minutes} Min.";
        }

        private void UpdateStatus(string status)
        {
            CurrentStatus = status;
            StatusChanged?.Invoke(status);
        }

        private void UpdateProgress(double value, bool isIndeterminate)
        {
            CurrentProgress = value;
            IsIndeterminate = isIndeterminate;
            ProgressChanged?.Invoke(value, isIndeterminate);
        }
    }
}