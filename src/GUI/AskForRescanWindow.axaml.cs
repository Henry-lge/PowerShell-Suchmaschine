using System;
using System.Threading.Tasks; 
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace FileSearcherApp
{
    public partial class AskForRescanWindow : Window
    {
        private readonly TextBlock? _messageText;

        // Ermöglicht das Warten auf die Antwort ohne offenen SplashScreen als Owner
        private readonly TaskCompletionSource<bool> _resultSource = new();

        public AskForRescanWindow()
        {
            InitializeComponent();
            _messageText = this.FindControl<TextBlock>("MessageText");

            //Falls das Fenster über das "X" geschlossen wird, Standardwert "false" liefern
            Closed += (_, _) => _resultSource.TrySetResult(false);
        }

        public AskForRescanWindow(DateTime lastUpdated) : this()
        {
            if (_messageText != null)
            {
                _messageText.Text =
                    $"Es existiert bereits eine Datenbank (letzte Aktualisierung am {lastUpdated:dd.MM.yyyy 'um' HH:mm 'Uhr'}).\n" +
                    "Möchtest du den Ordner erneut scannen?";
            }
        }

        //Wartet asynchron, bis der Nutzer einen Button geklickt hat
        public Task<bool> WaitForResultAsync() => _resultSource.Task;

        private void OnYesClicked(object? sender, RoutedEventArgs e)
        {
            _resultSource.TrySetResult(true); //Ergebnis setzen und Fenster schließen
            Close();
        }

        private void OnNoClicked(object? sender, RoutedEventArgs e)
        {
            _resultSource.TrySetResult(false); //Ergebnis setzen und Fenster schließen
            Close();
        }
    }
}