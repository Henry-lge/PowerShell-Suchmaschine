using System;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
namespace FileSearcherApp
{
    public partial class MainWindow : Window
    {
        private CancellationTokenSource? _cts;
        private readonly ObservableCollection<string> _fileTypes = new();

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

        private async void PerformSearch()
        {
            if (!_windowLoaded)
                return;

            _cts?.Cancel();
            using var searchCancellation = new CancellationTokenSource();
            _cts = searchCancellation;

            try
            {
                string query = SearchBox.Text?.Trim() ?? "";

                ResultsList.Items.Clear();

                if (string.IsNullOrWhiteSpace(query))
                {
                    SetCount(0);
                    ResultsList.Items.Add("Bitte einen Suchbegriff eingeben.");
                    return;
                }

                _search ??= SearchBridge.CreateDefault();

                var hits = await _search.SearchAsync(
                    query,
                    SearchLimit,
                    mode: _currentSearchMode,
                    ct: searchCancellation.Token,
                    extensions: new List<string>(_fileTypes));

                searchCancellation.Token.ThrowIfCancellationRequested();

                if (hits == null || hits.Count == 0)
                {
                    SetCount(0);
                    ResultsList.Items.Add("Keine Treffer gefunden.");
                    return;
                }

                SetCount(hits.Count);
                foreach (var hit in hits)
                {
                    ResultsList.Items.Add(hit);
                }
            }
            catch (Exception ex) when (!searchCancellation.IsCancellationRequested)
            {
                SetCount(0);
                ResultsList.Items.Clear();
                ResultsList.Items.Add($"Fehler: {ex.Message}");
            }
            catch (Exception) when (searchCancellation.IsCancellationRequested)
            {
                // Eine neuere Suche oder das Schließen des Fensters hat diese Suche abgelöst.
            }
            finally
            {
                if (ReferenceEquals(_cts, searchCancellation))
                    _cts = null;
            }
        }
    }
}