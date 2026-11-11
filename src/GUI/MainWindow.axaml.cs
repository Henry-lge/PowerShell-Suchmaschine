using System;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace FileSearcherApp
{
    public partial class MainWindow : Window
    {
        private ISearchService? _search;
        private bool _isSearching;

        public MainWindow()
        {
            InitializeComponent();
        }

        private async void OnSearchClicked(
            object? sender,
            RoutedEventArgs e)
        {
            if (_isSearching)
                return;

            _isSearching = true;
            var button = sender as Button;

            if (button != null)
                button.IsEnabled = false;

            ResultsList.Items.Clear();

            try
            {
                var query = SearchBox.Text ?? "";

                if (string.IsNullOrWhiteSpace(query))
                {
                    ResultsList.Items.Add(
                        "Bitte einen Suchbegriff eingeben.");
                    return;
                }

                _search ??= SearchBridge.CreateDefault();

                var hits = await _search.SearchAsync(query);

                if (hits.Count == 0)
                {
                    ResultsList.Items.Add("Keine Treffer gefunden.");
                    return;
                }

                foreach (var hit in hits)
                {
                    ResultsList.Items.Add(hit);
                }
            }
            catch (Exception ex)
            {
                ResultsList.Items.Add($"Fehler: {ex.Message}");
            }
            finally
            {
                _isSearching = false;

                if (button != null)
                    button.IsEnabled = true;
            }
        }
    }
}