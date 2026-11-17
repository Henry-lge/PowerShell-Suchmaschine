
using System;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using System.Diagnostics;
using System.IO;

namespace FileSearcherApp
{
    public partial class MainWindow : Window
    {
        private const int DebounceMs = 500;   // Pause nach der letzten Eingabe
        private const int MinChars = 2;       // kürzere Eingaben suchen wir nicht automatisch
        private CancellationTokenSource? _cts;   // gehört zur jeweils neuesten Eingabe
    
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

            //SearchBox.KeyDown += OnSearchKeyDown;
            SearchBox.TextChanged += OnSearchTextChanged;

            UpdateSearchWatermark();
        }

         // Live-Suche: nach jeder Eingabe warten, dann suchen
        private void OnSearchTextChanged(object? sender, TextChangedEventArgs e)
            => _ = RunSearchAsync(DebounceMs);

        // Button: sofort suchen, ohne Wartezeit
        private void OnSearchClicked(object? sender, RoutedEventArgs e)
            => _ = RunSearchAsync(0);

        private async Task RunSearchAsync(int delayMs)
        {
            // Wartende oder laufende Suche der vorherigen Eingabe abbrechen
            _cts?.Cancel();
            var cts = _cts = new CancellationTokenSource();
            var ct = cts.Token;

            var text = SearchBox.Text?.Trim() ?? "";
            if (text.Length == 0)
            {
                ResultsList.Items.Clear();
                SetCount(0); 
                return;
            }
            // Automatisch erst ab MinChars Zeichen; der Button sucht immer
            if (delayMs > 0 && text.Length < MinChars) return;

            try
            {
                if (delayMs > 0) await Task.Delay(delayMs, ct);

                _search ??= SearchBridge.CreateDefault();
                var hits = await _search.SearchAsync(text, ct: ct);

                // Falls inzwischen eine neuere Eingabe da ist, Ergebnis verwerfen
                ct.ThrowIfCancellationRequested();

                ResultsList.Items.Clear();
                SetCount(hits.Count);
                if (hits.Count == 0) { ResultsList.Items.Add("Keine Treffer."); return; }
                foreach (var hit in hits) ResultsList.Items.Add(hit);
            }
            catch (OperationCanceledException)
            {
                // normal: neuere Eingabe hat diese Suche abgelöst
            }
            catch (Exception ex)
            {
                if (ct.IsCancellationRequested) return;
                ResultsList.Items.Clear();
                SetCount(0);    
                ResultsList.Items.Add($"Fehler: {ex.Message}");
            }
        }    

     
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
