    using System;
    using System.Diagnostics;
    using System.IO; // Wichtig für Path.Combine und File.Exists
    using System.Runtime.InteropServices;
    using Avalonia.Controls;
    using Avalonia.Interactivity;

   namespace FileSearcherApp
{
    public partial class MainWindow : Window
    {
        private ISearchService? _search;

        public MainWindow()
        {
            InitializeComponent();
        }

        private async void OnSearchClicked(object? sender, RoutedEventArgs e)
        {
            ResultsList.Items.Clear();
            try
            {
                _search ??= SearchBridge.CreateDefault();
                var hits = await _search.SearchAsync(SearchBox.Text ?? "");

                if (hits.Count == 0) { ResultsList.Items.Add("Keine Treffer."); return; }
                foreach (var hit in hits) ResultsList.Items.Add(hit);
            }
            catch (Exception ex)
            {
                ResultsList.Items.Add($"Fehler: {ex.Message}");
            }
        }
    }
}