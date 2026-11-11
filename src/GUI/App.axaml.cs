using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using System.Threading.Tasks;

namespace FileSearcherApp
{
    public partial class App : Application
    {
        public override void Initialize()
        {
            AvaloniaXamlLoader.Load(this);
        }

        public override async void OnFrameworkInitializationCompleted()
        {
            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            {
                // 1. Splashscreen erstellen und anzeigen
                var splashScreen = new SplashScreenWindow();
                desktop.MainWindow = splashScreen;
                splashScreen.Show();
                // Hier könnte man dann vielleicht den Crawlerscan durchführen

                // 2. Im Hintergrund Aufgaben erledigen (z.B. PowerShell vorbereiten, Daten laden)
                await Task.Delay(4000); // Simuliert 4 Sekunden Ladezeit

                // 3. Echtes Hauptfenster öffnen
                var mainWindow = new MainWindow();
                desktop.MainWindow = mainWindow;
                mainWindow.Show();

                // 4. Splashscreen schließen
                splashScreen.Close();
            }

            base.OnFrameworkInitializationCompleted();
        }
    }
}