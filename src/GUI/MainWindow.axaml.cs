using System;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
namespace FileSearcherApp
{
    public partial class MainWindow : Window
    {
        //Live-Search
        private const int DebounceMs = 500;   // Pause nach der letzten Eingabe
        private const int MinChars = 2;       // kürzere Eingaben suchen wir nicht automatisch
        private CancellationTokenSource? _cts;   // gehört zur jeweils neuesten Eingabe


        //Sorting
        private enum SortKey { Relevance, Name, Type, Date }
        private SortKey _sortKey = SortKey.Relevance;
        private bool _sortAscending = true;
        private IReadOnlyList<SearchHit> _hits = Array.Empty<SearchHit>();
        private static readonly StringComparer Cmp = StringComparer.CurrentCultureIgnoreCase;
            
        //Searching + Loading    
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

            //Statusleiste & Fortschrittsbalken mit dem Hintergrund-Crawler verbinden
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

        private const int SearchLimit = 100;   // Limit von SearchAsync
        private void SetCount(int count)
        {
            // Wenn das Limit erreicht ist, kann es mehr Treffer geben, als angezeigt werden.
            ResultsCountText.Text = count >= SearchLimit
                ? $"Dateien gefunden: {count}+"
                : $"Dateien gefunden: {count}";
        }


        private void OnSearchKeyDown(object? sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
            {
                e.Handled = true;
                PerformSearch();
            }
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

        private void OnSearchHitTapped(object? sender, TappedEventArgs e)
{
    if (sender is not Border border ||
        border.DataContext is not SearchHit hit)
    {
        return;
    }

    e.Handled = true;

    if (!File.Exists(hit.Path))
    {
        ResultsCountText.Text = "Datei nicht mehr vorhanden.";
        return;
    }

    try
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = hit.Path,
            UseShellExecute = true
        });
    }
    catch (Exception ex)
        {
            ResultsCountText.Text = "Datei konnte nicht geöffnet werden.";
            ResultsCountText.SetValue(ToolTip.TipProperty, ex.Message);
        }
    }


        //Searching
        private async void PerformSearch()
        {
            if (!_windowLoaded || _isSearching)
                return;

            _isSearching = true;

            try
            {
                string query = SearchBox.Text?.Trim() ?? "";

                ResultsList.Items.Clear();
                _hits = Array.Empty<SearchHit>();               

                if (string.IsNullOrWhiteSpace(query))
                {
                    SetCount(0);
                    ResultsList.Items.Add("Bitte einen Suchbegriff eingeben.");
                    return;
                }

                _search ??= SearchBridge.CreateDefault();

                int limit = SearchLimit;
                string? extension = null;

                var hits = await _search.SearchAsync(
                    query,
                    limit,
                    extension,
                    _currentSearchMode);

                if (hits == null || hits.Count == 0)
                {
                    SetCount(0);
                    ResultsList.Items.Add("Keine Treffer gefunden.");
                    return;
                }

                _hits = hits;                                   
                SetCount(hits.Count);
                ShowHits();                                       
            }
            catch (Exception ex)
            {
                _hits = Array.Empty<SearchHit>();                 
                SetCount(0);
                ResultsList.Items.Clear();
                ResultsList.Items.Add($"Fehler: {ex.Message}");
            }
            finally
            {
                _isSearching = false;
            }
        }

        //Sorting  
        private void OnSortHeaderTapped(object? sender, TappedEventArgs e)
        {
            if (sender is not TextBlock { Tag: string tag }) return;
            var key = tag switch { "Name" => SortKey.Name, "Type" => SortKey.Type, "Date" => SortKey.Date, _ => SortKey.Relevance };

            if (key == _sortKey && key != SortKey.Type)
                _sortAscending = !_sortAscending;
            else
            {
                _sortKey = key;
                // _sortAscending = key != SortKey.Date; <- Wir können das aus Kommentar ziehen, 
                // damit wir für Daten erst neue bekommen haben, aber die Pfeil dann beim Start andersrum gedreht
             }

            UpdateSortLabels();
            if (_hits.Count > 0) ShowHits();
        }

        private void UpdateSortLabels()
        {
            string Arrow(SortKey k) => _sortKey != k ? "" : (_sortAscending ? " ↓" : " ↑");
            SortNameHeader.Text = "Datei" + Arrow(SortKey.Name);
            SortTypeHeader.Text = "Typ" + Arrow(SortKey.Type);
            SortDateHeader.Text = "Geändert" + Arrow(SortKey.Date);
        }

        private void ShowHits()
        {
            IEnumerable<SearchHit> sorted = _sortKey switch
            {
                SortKey.Name => _sortAscending
                    ? _hits.OrderBy(h => h.FileName, Cmp)
                    : _hits.OrderByDescending(h => h.FileName, Cmp),
                SortKey.Type => _hits.OrderBy(h => h.Extension, Cmp).ThenBy(h => h.FileName, Cmp),
                SortKey.Date => _sortAscending
                    ? _hits.OrderBy(h => h.LastWriteUtc)
                    : _hits.OrderByDescending(h => h.LastWriteUtc),
                _ => _hits
            };

            ResultsList.Items.Clear();
            foreach (var hit in sorted) ResultsList.Items.Add(hit);
        }

    }
}