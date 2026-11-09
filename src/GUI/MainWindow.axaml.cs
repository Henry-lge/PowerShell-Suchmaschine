using System;
using System.Diagnostics;
using System.IO; // Wichtig für Path.Combine und File.Exists
using System.Runtime.InteropServices;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace FileSearcherApp
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();
        }

        private void OnSearchClicked(object? sender, RoutedEventArgs e)
        {
            ResultsList.Items.Clear();

            // 1. PowerShell-Version prüfen
            string powershellExe = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) 
                ? "powershell.exe" 
                : "pwsh";

            // Das ist der Skriptpfad
            // 
            // Wichtig ist, dass die Datei dann im .csproj abgelegt wird. 
            // Wenn die .ps1 intern andere aufruft müssen die aufgerufenen nicht da abgelegt werden 
            string scriptPath =  "test.ps1";

            if (!File.Exists(scriptPath))
            {
                ResultsList.Items.Add($"Fehler: 'test.ps1' wurde hier nicht gefunden:");
                ResultsList.Items.Add(scriptPath);
                return;
            }

            // Hier könnte man dann vlt. die Suchparameter machen
            string arguments = $"-ExecutionPolicy Bypass -File \"{scriptPath}\"";

            var psi = new ProcessStartInfo
            {
                FileName = powershellExe,
                Arguments = arguments,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            //Auslesung vom Skript
            try
            {
                using var process = Process.Start(psi);
                if (process != null)
                {
                    string output = process.StandardOutput.ReadToEnd();
                    string error = process.StandardError.ReadToEnd();
                    process.WaitForExit();

                    if (!string.IsNullOrEmpty(error))
                    {
                        ResultsList.Items.Add($"PowerShell-Fehler: {error.Trim()}");
                    }

                    if (!string.IsNullOrWhiteSpace(output))
                    {
                        var lines = output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                        foreach (var line in lines)
                        {
                            ResultsList.Items.Add(line);
                        }
                    }
                    else
                    {
                        ResultsList.Items.Add("Skript hat keine Ausgabe zurückgegeben.");
                    }
                }
            }
            catch (Exception ex)
            {
                ResultsList.Items.Add($"Fehler beim Starten von PowerShell: {ex.Message}");
            }
        }
    }
}