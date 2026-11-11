using System;
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
            if (ApplicationLifetime is
                IClassicDesktopStyleApplicationLifetime desktop)
            {
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

                await Task.Delay(4000); // TemporäreSimulation

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
    }
}
