using System;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace FileSearcherApp
{
    public partial class App : Application
    {
        public override void Initialize()
        {
            AvaloniaXamlLoader.Load(this);
        }

        public override void OnFrameworkInitializationCompleted()
        {
            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            {
                var splashScreen = new SplashScreenWindow();

                desktop.MainWindow = splashScreen;
                splashScreen.Show();

                // Startet den gesamten Initialisierungs- und Scan-Prozess im Hintergrund
                _ = InitializeApplicationAsync(desktop, splashScreen);
            }

            base.OnFrameworkInitializationCompleted();
        }

        private async Task InitializeApplicationAsync(
            IClassicDesktopStyleApplicationLifetime desktop,
            SplashScreenWindow splashScreen)
        {
            try
            {
                // Echten Crawler-Scan im Hintergrund ausführen
                await Task.Run(() => StartCrawlerScan(splashScreen));

                // Nach erfolgreichem Scan Hauptfenster laden
                var mainWindow = new MainWindow();
                desktop.MainWindow = mainWindow;
                mainWindow.Show();

                splashScreen.Close();
            }
            catch (Exception ex)
            {
                splashScreen.Close();

                var errorWindow = new Avalonia.Controls.Window
                {
                    Title = "Startfehler",
                    Width = 450,
                    Height = 180,
                    Content = new Avalonia.Controls.TextBlock
                    {
                        Text = $"Die Anwendung konnte nicht gestartet werden:\n{ex.Message}",
                        Margin = new Avalonia.Thickness(20),
                        TextWrapping = Avalonia.Media.TextWrapping.Wrap
                    }
                };

                desktop.MainWindow = errorWindow;
                errorWindow.Show();
            }
        }

        private void StartCrawlerScan(SplashScreenWindow splashScreen)
        {
            try
            {
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                
                string? currentDir = baseDir;
                while (currentDir != null && !File.Exists(Path.Combine(currentDir, "PowerShell-Suchmaschine.sln")) && Path.GetFileName(currentDir) != "PowerShell-Suchmaschine")
                {
                    var parent = Directory.GetParent(currentDir);
                    if (parent == null) break;
                    currentDir = parent.FullName;
                }

                string projectRoot = currentDir ?? Path.GetFullPath(Path.Combine(baseDir, "../../../"));
                string crawlerModulePath = Path.Combine(projectRoot, "src", "Crawler", "Crawler.psm1");

                if (!File.Exists(crawlerModulePath))
                {
                    Console.WriteLine($"[FEHLER] Modul nicht gefunden unter: {crawlerModulePath}");
                    return;
                }

                string scanFolder = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

                string psCommand = $@"
                    using module '{crawlerModulePath}'; 
                    $c = [Crawler]::new(); 
                    $c.ProgressOutput = $true; 
                    $c.ProgressInterval = 100; 
                    try {{ 
                        $c.ScanFolder('{scanFolder}') 
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

                process.OutputDataReceived += (sender, e) =>
                {
                    if (string.IsNullOrWhiteSpace(e.Data)) return;

                    if (e.Data.StartsWith("Scanned:"))
                    {
                        var match = Regex.Match(e.Data, @"Scanned:\s*(\d+)");
                        if (match.Success)
                        {
                            string count = match.Groups[1].Value;
                            splashScreen.UpdateStatus($"Dateien werden indiziert... ({count} verarbeitet)");
                        }
                    }
                    else if (e.Data.StartsWith("Read:"))
                    {
                        var match = Regex.Match(e.Data, @"Read:\s*(\d+)\s*of\s*(\d+)");
                        if (match.Success &&
                            double.TryParse(match.Groups[1].Value, out double done) &&
                            double.TryParse(match.Groups[2].Value, out double total))
                        {
                            if (total > 0)
                            {
                                double percent = (done / total) * 100;
                                splashScreen.UpdateProgress(percent, isIndeterminate: false);
                                splashScreen.UpdateStatus($"Dateiinhalte werden gelesen... ({done}/{total})");
                            }
                        }
                    }
                };

                process.Start();
                process.BeginOutputReadLine();
                process.WaitForExit();

                splashScreen.UpdateStatus("Fertiggestellt!");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Prozess-Fehler: {ex.Message}");
            }
        }
    }
}