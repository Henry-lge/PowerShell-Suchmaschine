using System;
using System.Collections.Generic;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading; // <--- NEU: Für thread-sichere UI-Updates aus dem Hintergrund

namespace FileSearcherApp
{
    public partial class MainWindow : Window
    {
        private ISearchService? _search;
        private bool _isSearching;
        private bool _windowLoaded;

        private string _currentSearchMode = "FileName";
        private string _currentSortOrder = "Ascending";

        public MainWindow()
        {
            InitializeComponent();

            string username = Environment.UserName;
            WelcomeText.Text = $"Hallo {username}!";

            // Erst nach dem Laden auf Ereignisse reagieren.
            _windowLoaded = true;

            SearchBox.KeyDown += OnSearchKeyDown;

            UpdateSearchWatermark();

            // <--- NEU: Statusleiste & Fortschrittsbalken mit dem Hintergrund-Crawler verbinden
            InitializeCrawlerStatus();
        }

        private void InitializeCrawlerStatus()
        {
            var statusText = this.FindControl<TextBlock>("ScanStatusText");
            var progressBar = this.FindControl<ProgressBar>("ScanProgressBar");

            // Aktuellen Stand direkt beim Öffnen des Fensters übernehmen
            if (statusText != null)
            {
                statusText.Text = App.CrawlerService.CurrentStatus;
            }

            if (progressBar != null)
            {
                progressBar.IsVisible = App.CrawlerService.IsScanning;
                progressBar.IsIndeterminate = App.CrawlerService.IsIndeterminate;
                progressBar.Value = App.CrawlerService.CurrentProgress;
            }

            // Event-Handler für Live-Updates definieren
            void OnStatusChanged(string status) =>
                Dispatcher.UIThread.Post(() =>
                {
                    if (statusText != null)
                    {
                        statusText.Text = status;
                    }
                });

            void OnProgressChanged(double val, bool isIndeterminate) =>
                Dispatcher.UIThread.Post(() =>
                {
                    if (progressBar != null)
                    {
                        progressBar.IsVisible = true;
                        progressBar.IsIndeterminate = isIndeterminate;
                        progressBar.Value = val;
                    }
                });

            void OnScanCompleted() =>
                Dispatcher.UIThread.Post(() =>
                {
                    if (progressBar != null)
                    {
                        progressBar.IsVisible = false;
                    }
                });

            // Events abonnieren
            App.CrawlerService.StatusChanged += OnStatusChanged;
            App.CrawlerService.ProgressChanged += OnProgressChanged;
            App.CrawlerService.ScanCompleted += OnScanCompleted;

            // Events beim Schließen des Fensters sauber abmelden
            Closed += (_, _) =>
            {
                App.CrawlerService.StatusChanged -= OnStatusChanged;
                App.CrawlerService.ProgressChanged -= OnProgressChanged;
                App.CrawlerService.ScanCompleted -= OnScanCompleted;
            };
        }
        // =========================================================================

        private void OnFilterMenuItemClick(
            object? sender,
            RoutedEventArgs e)
        {
            if (sender is MenuItem menuItem &&
                menuItem.Tag is string filterMode)
            {
                _currentSearchMode = filterMode;

                UpdateSearchWatermark();

                PerformSearch();
            }
        }

        private void UpdateSearchWatermark()
        {
            SearchBox.Watermark = _currentSearchMode switch
            {
                "FileName" => "Nach Dateinamen suchen...",
                "Content" => "Nach Dateiinhalt suchen...",
                "Both" => "Nach Name und Inhalt suchen...",
                _ => "Suchbegriff eingeben..."
            };
        }

        private void OnSearchKeyDown(object? sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
            {
                e.Handled = true;
                PerformSearch();
            }
        }

        private void OnSearchClicked(object? sender, RoutedEventArgs e)
        {
            PerformSearch();
        }

        private void OnSortMenuItemClick(
            object? sender,
            RoutedEventArgs e)
        {
            if (sender is MenuItem menuItem &&
                menuItem.Tag is string tag)
            {
                _currentSortOrder = tag;
                PerformSearch();
            }
        }

        private async void PerformSearch()
        {
            if (_isSearching)
                return;

            _isSearching = true;

            try
            {
                string query = SearchBox.Text ?? "";

                if (string.IsNullOrWhiteSpace(query))
                {
                    ResultsList.ItemsSource =
                        new List<string>
                        {
                            "Bitte einen Suchbegriff eingeben."
                        };
                    return;
                }

                _search ??= SearchBridge.CreateDefault();

                int limit = 100;
                string? extension = null;

                var hits = await _search.SearchAsync(
                    query,
                    limit,
                    extension,
                    _currentSearchMode);

                if (hits == null || hits.Count == 0)
                {
                    ResultsList.ItemsSource =
                        new List<string>
                        {
                            "Keine Treffer gefunden."
                        };
                    return;
                }

                ResultsList.ItemsSource = hits;
            }
            catch (Exception ex)
            {
                ResultsList.ItemsSource =
                    new List<string>
                    {
                        $"Fehler: {ex.Message}"
                    };
            }
            finally
            {
                _isSearching = false;
            }
        }
    }
}