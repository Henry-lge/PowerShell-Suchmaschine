using Avalonia.Controls;
using Avalonia.Threading;

namespace FileSearcherApp
{
    public partial class SplashScreenWindow : Window
    {
        // <--- NEU: Referenzen auf die XAML-Steuerelemente
        private readonly TextBlock? _statusTextBlock;
        private readonly ProgressBar? _crawlerProgressBar;

        public SplashScreenWindow()
        {
            InitializeComponent();

            // <--- NEU: Steuerelemente sicher verknüpfen
            _statusTextBlock = this.FindControl<TextBlock>("StatusTextBlock");
            _crawlerProgressBar = this.FindControl<ProgressBar>("CrawlerProgressBar");
        }

        public void UpdateStatus(string message)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (_statusTextBlock != null)
                {
                    _statusTextBlock.Text = message;
                }
            });
        }

        public void UpdateProgress(double value, bool isIndeterminate = false)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (_crawlerProgressBar != null)
                {
                    _crawlerProgressBar.IsIndeterminate = isIndeterminate;
                    _crawlerProgressBar.Value = value;
                }
            });
        }
    }
}