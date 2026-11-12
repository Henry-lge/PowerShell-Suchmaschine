using Avalonia.Controls;
using Avalonia.Threading; // <--- NEU: Für Dispatcher.UIThread

namespace FileSearcherApp
{
    public partial class SplashScreenWindow : Window
    {
        public SplashScreenWindow()
        {
            InitializeComponent();
        }

    

        // =========================================================================
        // NEU: Helfermethoden für App.axaml.cs (aktualisieren Status & Ladebalken)
        // =========================================================================

        public void UpdateStatus(string message)
        {
            Dispatcher.UIThread.Post(() =>
            {
                StatusTextBlock.Text = message;
            });
        }

        public void UpdateProgress(double value, bool isIndeterminate = false)
        {
            Dispatcher.UIThread.Post(() =>
            {
                CrawlerProgressBar.IsIndeterminate = isIndeterminate;
                CrawlerProgressBar.Value = value;
            });
        }
    }
}