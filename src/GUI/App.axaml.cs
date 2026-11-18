using System;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls; 
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace FileSearcherApp
{
    public partial class App : Application
    {
        public static CrawlerService CrawlerService { get; } = new CrawlerService();

        public override void Initialize()
        {
            AvaloniaXamlLoader.Load(this);
        }

        public override void OnFrameworkInitializationCompleted()
        {
            if (ApplicationLifetime is
                IClassicDesktopStyleApplicationLifetime desktop)
            {
                desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;

                desktop.Exit += (_, _) => CrawlerService.StopScan();

                var splashScreen = new SplashScreenWindow();

                desktop.MainWindow = splashScreen;
                splashScreen.Show();

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

                // SplashScreen 2 Sekunden anzeigen
                await Task.Delay(2000);

                if (CrawlerService.TryGetExistingDatabaseLastWriteTime(out DateTime lastUpdated))
                {
                    var dialog = new AskForRescanWindow(lastUpdated);

                    desktop.MainWindow = dialog;
                    dialog.Show();
                    splashScreen.Close();

                    bool shouldRescan = await dialog.WaitForResultAsync();

                    if (shouldRescan)
                    {
                        CrawlerService.StartBackgroundScan();
                    }
                    else
                    {
                        CrawlerService.SkipInitialScan(lastUpdated);
                    }
                }
                else
                {
                    splashScreen.UpdateStatus("Erstelle neuen Suchindex...");
                    CrawlerService.StartBackgroundScan();
                    await Task.Delay(500);

                    // <--- GEÄNDERT: SplashScreen schließen, bevor MainWindow erscheint
                    splashScreen.Close();
                }

                // Hauptfenster laden (Suche ist sofort nutzbar)
                var mainWindow = new MainWindow();
                desktop.MainWindow = mainWindow;

                // Normales Beenden der App aktivieren, sobald das Hauptfenster geschlossen wird
                desktop.ShutdownMode = ShutdownMode.OnMainWindowClose;

                mainWindow.Show();
            }
            catch (Exception ex)
            {
                splashScreen.Close();

                var errorWindow = new Window
                {
                    Title = "Startfehler",
                    Width = 450,
                    Height = 180,
                    Content = new TextBlock
                    {
                        Text = $"Die Anwendung konnte nicht gestartet werden:\n{ex.Message}",
                        Margin = new Thickness(20),
                        TextWrapping = Avalonia.Media.TextWrapping.Wrap
                    }
                };

                desktop.MainWindow = errorWindow;
                desktop.ShutdownMode = ShutdownMode.OnMainWindowClose; 
                errorWindow.Show();
            }
        }
    }
}