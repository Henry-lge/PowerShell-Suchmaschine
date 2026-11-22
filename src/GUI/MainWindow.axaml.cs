using System;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Collections.ObjectModel;
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
        private readonly ObservableCollection<string> _fileTypes = new();

        // Live-Search
        private const int DebounceMs = 500;   // Pause nach der letzten Eingabe
        private const int MinChars = 2;       // kürzere Eingaben suchen wir nicht automatisch
        private CancellationTokenSource? _cts;   // gehört zur jeweils neuesten Eingabe

        // Sorting
        private enum SortKey { Relevance, Name, Type, Date }
        private SortKey _sortKey = SortKey.Relevance;
        private bool _sortAscending = true;
        private IReadOnlyList<SearchHit> _hits = Array.Empty<SearchHit>();
        private static readonly StringComparer Cmp = StringComparer.CurrentCultureIgnoreCase;

        // Searching + Loading
        private ISearchService? _search;
        private bool _windowLoaded;

        private string _currentSearchMode = "FileName";
        private string _currentSortOrder = "Ascending";

        public MainWindow()
        {
            InitializeComponent();

            FileTypeList.ItemsSource = _fileTypes;
            Closed += (_, _) => _cts?.Cancel();
            InitializeAppearance();

            // Erst nach dem Laden auf Ereignisse reagieren.
            _windowLoaded = true;

            SearchBox.TextChanged += OnSearchTextChanged;
            SearchBox.KeyDown += OnSearchKeyDown;

            UpdateSearchWatermark();

            // Statusleiste & Fortschrittsbalken mit dem Hintergrund-Crawler verbinden
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

        private void OnFilterFlyoutOpened(object? sender, EventArgs e)
        {
            FileTypeBox.Focus();
        }

        private void OnFileTypeKeyDown(object? sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
            {
                e.Handled = true;
                AddFileTypes();
            }
        }

        private void OnAddFileTypesClick(object? sender, RoutedEventArgs e)
        {
            AddFileTypes();
            FileTypeBox.Focus();
        }

        private void AddFileTypes()
        {
            var input = FileTypeBox.Text ?? "";
            var extensions = new List<string>();
            foreach (var entry in input.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
            {
                var extension = entry.StartsWith('.') ? entry[1..] : entry;
                if (extension.Length == 0 ||
                    extension.IndexOfAny(['.', '/', '\\']) >= 0 ||
                    Array.Exists(extension.ToCharArray(), char.IsWhiteSpace))
                {
                    FileTypeErrorText.Text = $"Ungültige Dateiendung: {entry}";
                    FileTypeErrorText.IsVisible = true;
                    return;
                }

                var normalized = "." + extension.ToLowerInvariant();
                if (!_fileTypes.Contains(normalized) && !extensions.Contains(normalized))
                    extensions.Add(normalized);
            }

            FileTypeBox.Clear();
            FileTypeErrorText.IsVisible = false;
            foreach (var extension in extensions)
                _fileTypes.Add(extension);
            if (extensions.Count > 0)
                ApplyFileTypeFilter();
        }

        private void OnRemoveFileTypeClick(object? sender, RoutedEventArgs e)
        {
            if (sender is Button { DataContext: string extension } && _fileTypes.Remove(extension))
                ApplyFileTypeFilter();
        }

        private void ApplyFileTypeFilter()
        {
            if (!string.IsNullOrWhiteSpace(SearchBox.Text))
                PerformSearch();
        }

        private void OnSearchModeChanged(object? sender, SelectionChangedEventArgs e)
        {
            if (_windowLoaded && sender is ComboBox { SelectedItem: ComboBoxItem { Tag: string mode } })
            {
                _currentSearchMode = mode;
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

        private void OnSearchTextChanged(object? sender, TextChangedEventArgs e)
        {
            if (!_windowLoaded)
                return;

            _ = ExecuteSearchAsync(DebounceMs);
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

        // Searching
        private void PerformSearch()
        {
            if (!_windowLoaded)
                return;

            _ = ExecuteSearchAsync(0);
        }

        private async Task ExecuteSearchAsync(int delayMs)
        {
            _cts?.Cancel();
            var cts = new CancellationTokenSource();
            _cts = cts;
            var ct = cts.Token;

            try
            {
                if (delayMs > 0)
                {
                    await Task.Delay(delayMs, ct);
                }

                string query = SearchBox.Text?.Trim() ?? "";

                if (string.IsNullOrWhiteSpace(query))
                {
                    _hits = Array.Empty<SearchHit>();
                    SetCount(0);
                    ResultsList.Items.Clear();
                    ResultsList.Items.Add("Bitte einen Suchbegriff eingeben.");
                    return;
                }

                // Bei Live-Suche erst ab MinChars Zeichen suchen; Enter/Filter/Moduswechsel suchen immer
                if (delayMs > 0 && query.Length < MinChars)
                {
                    return;
                }

                _search ??= SearchBridge.CreateDefault();

                var hits = await _search.SearchAsync(
                    query,
                    SearchLimit,
                    mode: _currentSearchMode,
                    ct: ct,
                    extensions: new List<string>(_fileTypes));

                ct.ThrowIfCancellationRequested();

                ResultsList.Items.Clear();

                if (hits == null || hits.Count == 0)
                {
                    _hits = Array.Empty<SearchHit>();
                    SetCount(0);
                    ResultsList.Items.Add("Keine Treffer gefunden.");
                    return;
                }

                _hits = hits;
                SetCount(hits.Count);
                ShowHits();
            }
            catch (OperationCanceledException)
            {
                // Eine neuere Eingabe oder das Schließen des Fensters hat diese Suche abgelöst.
            }
            catch (Exception ex)
            {
                if (ct.IsCancellationRequested)
                    return;

                _hits = Array.Empty<SearchHit>();
                SetCount(0);
                ResultsList.Items.Clear();
                ResultsList.Items.Add($"Fehler: {ex.Message}");
            }
            finally
            {
                if (ReferenceEquals(_cts, cts))
                    _cts = null;
                cts.Dispose();
            }
        }

        // Sorting
        private void OnSortHeaderTapped(object? sender, TappedEventArgs e)
        {
            if (sender is not TextBlock { Tag: string tag }) return;
            var key = tag switch { "Name" => SortKey.Name, "Type" => SortKey.Type, "Date" => SortKey.Date, _ => SortKey.Relevance };

            if (key == _sortKey)
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
                SortKey.Type => _sortAscending
                    ? _hits.OrderBy(h => h.Extension, Cmp).ThenBy(h => h.FileName, Cmp)
                    : _hits.OrderByDescending(h => h.Extension, Cmp).ThenBy(h => h.FileName, Cmp),
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