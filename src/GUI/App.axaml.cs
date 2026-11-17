using System;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls; // <--- NEU: Für den Abfrage-Dialog (Window, Button, StackPanel, Border)
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Layout; // <--- NEU: Für HorizontalAlignment / VerticalAlignment
using Avalonia.Markup.Xaml;
using Avalonia.Media; // <--- NEU: Für Farb-Styling des Dialogs passend zum SplashScreen

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
            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            {
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
                // =====================================================================
                // NEU: Prüfen, ob bereits eine Datenbank existiert, und ggf. nachfragen
                // =====================================================================
                if (CrawlerService.TryGetExistingDatabaseLastWriteTime(out DateTime lastUpdated))
                {
                    splashScreen.UpdateStatus("Bestehende Datenbank gefunden...");

                    bool shouldRescan = await AskForRescanAsync(splashScreen, lastUpdated);

                    if (shouldRescan)
                    {
                        splashScreen.UpdateStatus("Starte erneuten Hintergrund-Scan...");
                        CrawlerService.StartBackgroundScan();
                        await Task.Delay(800);
                    }
                    else
                    {
                        CrawlerService.SkipInitialScan(lastUpdated);
                    }
                }
                else
                {
                    // Noch keine Datenbank vorhanden -> direkt ersten Scan starten
                    splashScreen.UpdateStatus("Erstelle neuen Suchindex...");
                    CrawlerService.StartBackgroundScan();
                    await Task.Delay(1200);
                }
                // =====================================================================

                // Hauptfenster laden (Suche ist sofort nutzbar)
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

        // =========================================================================
        // NEU: Bestätigungsdialog mit Datum der letzten Datenbank-Aktualisierung
        // =========================================================================
        private async Task<bool> AskForRescanAsync(Window owner, DateTime lastUpdated)
        {
            bool rescanConfirmed = false;

            var dialog = new Window
            {
                Title = "Suchindex aktualisieren?",
                Width = 460,
                Height = 200,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                CanResize = false,
                SystemDecorations = SystemDecorations.BorderOnly,
                Background = new SolidColorBrush(Color.Parse("#0c3835"))
            };

            var yesButton = new Button
            {
                Content = "Ja, erneut scannen",
                Background = new SolidColorBrush(Color.Parse("#196b65")),
                Foreground = Brushes.White,
                Padding = new Thickness(14, 8),
                Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand)
            };

            var noButton = new Button
            {
                Content = "Nein, bestehenden Index nutzen",
                Background = new SolidColorBrush(Color.Parse("#082624")),
                Foreground = new SolidColorBrush(Color.Parse("#80A09F")),
                Padding = new Thickness(14, 8),
                Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand)
            };

            yesButton.Click += (_, _) =>
            {
                rescanConfirmed = true;
                dialog.Close();
            };

            noButton.Click += (_, _) =>
            {
                rescanConfirmed = false;
                dialog.Close();
            };

            var buttonPanel = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Spacing = 10,
                Margin = new Thickness(0, 15, 0, 0),
                Children = { noButton, yesButton }
            };

            var contentPanel = new StackPanel
            {
                Margin = new Thickness(24),
                Spacing = 10,
                VerticalAlignment = VerticalAlignment.Center,
                Children =
                {
                    new TextBlock
                    {
                        Text = "Vorhandener Suchindex gefunden",
                        FontSize = 16,
                        FontWeight = FontWeight.Bold,
                        Foreground = Brushes.White
                    },
                    new TextBlock
                    {
                        Text = $"Es existiert bereits eine Datenbank (letzte Aktualisierung am {lastUpdated:dd.MM.yyyy 'um' HH:mm 'Uhr'}).\nMöchtest du den Ordner erneut scannen?",
                        FontSize = 13,
                        Foreground = new SolidColorBrush(Color.Parse("#B8D0CF")),
                        TextWrapping = TextWrapping.Wrap
                    },
                    buttonPanel
                }
            };

            dialog.Content = new Border
            {
                BorderBrush = new SolidColorBrush(Color.Parse("#196b65")),
                BorderThickness = new Thickness(1),
                Child = contentPanel
            };

            await dialog.ShowDialog(owner);
            return rescanConfirmed;
        }
        // =========================================================================
    }
}