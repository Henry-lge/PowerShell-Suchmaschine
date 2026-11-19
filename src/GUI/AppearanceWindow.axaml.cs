using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;

namespace FileSearcherApp
{
    public partial class AppearanceWindow : Window
    {
        private const int WheelSize = 220;

        private readonly Action<AppearancePreferences> _preview;
        private readonly Action<AppearancePreferences> _save;
        private readonly WriteableBitmap _wheel;
        private AppearancePreferences _draft;
        private Button? _activeRow;
        private HsvColor _selection;
        private bool _ready;
        private bool _syncingColor;

        internal AppearanceWindow(
            AppearancePreferences appearance, IResourceDictionary themeResources,
            Action<AppearancePreferences> preview, Action<AppearancePreferences> save)
        {
            _draft = appearance;
            _preview = preview;
            _save = save;

            InitializeComponent();
            foreach (var (key, value) in themeResources)
                Resources[key] = value;

            _wheel = CreateWheel();
            WheelImage.Source = _wheel;
            Closed += (_, _) =>
            {
                WheelImage.Source = null;
                _wheel.Dispose();
            };

            GreetingNameBox.Text = appearance.GreetingName;
            var fonts = FontManager.Current.SystemFonts
                .Select(font => font.Name)
                .Distinct(StringComparer.CurrentCultureIgnoreCase)
                .Order(StringComparer.CurrentCultureIgnoreCase)
                .Select(name => new FontOption(name, name))
                .Prepend(new FontOption("Systemschrift", null))
                .ToArray();
            FontBox.ItemsSource = fonts;
            FontBox.SelectedItem = fonts.FirstOrDefault(font =>
                string.Equals(font.Name, appearance.FontName, StringComparison.OrdinalIgnoreCase)) ?? fonts[0];

            _ready = true;
            SelectColorRow(PrimaryColorRow);
            PreviewAppearance();
        }

        private void OnColorRowClick(object? sender, RoutedEventArgs e)
        {
            if (sender is Button row)
            {
                if (AppearancePreferences.TryNormalizeColor(HexColorBox.Text, out var hex) &&
                    hex != ToHex(_selection.ToRgb()))
                {
                    ApplyColorEdit(Color.Parse(hex).ToHsv());
                }
                SelectColorRow(row);
            }
        }

        private void SelectColorRow(Button row)
        {
            _activeRow?.Classes.Remove("selected");
            _activeRow = row;
            row.Classes.Add("selected");
            ColorTitle.Text = AutomationProperties.GetName(row);
            OptionsMessage.Text = "";

            var hex = row == PrimaryColorRow ? _draft.PrimaryColor
                : row == SecondaryColorRow ? _draft.SecondaryColor : _draft.TextColor;
            SetSelectedColor(Color.Parse(hex).ToHsv());
        }

        private void OnWheelPressed(object? sender, PointerPressedEventArgs e)
        {
            if (!e.GetCurrentPoint(WheelSurface).Properties.IsLeftButtonPressed)
                return;

            WheelSurface.Focus();
            e.Pointer.Capture(WheelSurface);
            SelectWheelPoint(e.GetPosition(WheelSurface));
            e.Handled = true;
        }

        private void OnWheelMoved(object? sender, PointerEventArgs e)
        {
            if (e.Pointer.Captured == WheelSurface)
                SelectWheelPoint(e.GetPosition(WheelSurface));
        }

        private void OnWheelReleased(object? sender, PointerReleasedEventArgs e)
        {
            if (e.Pointer.Captured == WheelSurface)
            {
                SelectWheelPoint(e.GetPosition(WheelSurface));
                e.Pointer.Capture(null);
                e.Handled = true;
            }
        }

        private void SelectWheelPoint(Point point)
        {
            var x = point.X - WheelSize / 2.0;
            var y = point.Y - WheelSize / 2.0;
            var (hue, saturation) = WheelCoordinates(x, y);
            // Ein Klick auf Schwarz soll den gewählten Farbton sichtbar machen.
            var brightness = _selection.V == 0 ? 0.65 : _selection.V;
            ApplyColorEdit(new HsvColor(1, hue, Math.Min(saturation, 1), brightness));
        }

        private void OnWheelKeyDown(object? sender, KeyEventArgs e)
        {
            double hue = _selection.H;
            double saturation = _selection.S;
            switch (e.Key)
            {
                case Key.Left: hue -= 5; break;
                case Key.Right: hue += 5; break;
                case Key.Down: saturation -= 0.05; break;
                case Key.Up: saturation += 0.05; break;
                default: return;
            }

            var brightness = _selection.V == 0 ? 0.65 : _selection.V;
            ApplyColorEdit(new HsvColor(1, (hue + 360) % 360,
                Math.Clamp(saturation, 0, 1), brightness));
            e.Handled = true;
        }

        private void OnBrightnessChanged(object? sender, RangeBaseValueChangedEventArgs e)
        {
            if (_ready && !_syncingColor)
                ApplyColorEdit(new HsvColor(1, _selection.H, _selection.S, e.NewValue));
        }

        private void OnHexChanged(object? sender, TextChangedEventArgs e)
        {
            if (_ready && AppearancePreferences.TryNormalizeColor(HexColorBox.Text, out var hex) &&
                hex != ToHex(_selection.ToRgb()))
            {
                ApplyColorEdit(Color.Parse(hex).ToHsv(), updateHex: false);
            }
        }

        private void ApplyColorEdit(HsvColor selection, bool updateHex = true)
        {
            SetSelectedColor(selection, updateHex);
            var hex = ToHex(selection.ToRgb());
            _draft = _activeRow == PrimaryColorRow ? _draft with { PrimaryColor = hex }
                : _activeRow == SecondaryColorRow ? _draft with { SecondaryColor = hex }
                : _draft with { TextColor = hex };
            OptionsMessage.Text = "";
            PreviewAppearance();
        }

        private void SetSelectedColor(HsvColor selection, bool updateHex = true)
        {
            _selection = selection;
            _syncingColor = true;
            BrightnessSlider.Value = selection.V;
            _syncingColor = false;
            var color = selection.ToRgb();
            if (updateHex)
                HexColorBox.Text = ToHex(color);
            ColorPreview.Background = new SolidColorBrush(color);

            var radians = selection.H * Math.PI / 180;
            var center = WheelSize / 2.0;
            var radius = selection.S * center;
            var left = center + Math.Cos(radians) * radius - WheelMarker.Width / 2;
            var top = center + Math.Sin(radians) * radius - WheelMarker.Height / 2;
            Canvas.SetLeft(WheelMarker, left);
            Canvas.SetTop(WheelMarker, top);
            Canvas.SetLeft(WheelMarkerOutline, left);
            Canvas.SetTop(WheelMarkerOutline, top);
        }

        private void OnFontChanged(object? sender, SelectionChangedEventArgs e)
        {
            if (_ready && FontBox.SelectedItem is FontOption font)
            {
                _draft = _draft with { FontName = font.Name };
                PreviewAppearance();
            }
        }

        private void OnGreetingNameChanged(object? sender, TextChangedEventArgs e)
        {
            if (_ready)
            {
                _draft = _draft with { GreetingName = GreetingNameBox.Text?.Trim() ?? "" };
                PreviewAppearance();
            }
        }

        private void PreviewAppearance()
        {
            FontFamily = _draft.FontName is { Length: > 0 } name
                ? new FontFamily(name)
                : FontFamily.Default;
            _preview(_draft);
        }

        private void OnSaveClick(object? sender, RoutedEventArgs e)
        {
            if (!AppearancePreferences.TryNormalizeColor(HexColorBox.Text, out var hex))
            {
                OptionsMessage.Text = "Gib einen Hex-Farbwert wie #0C3835 ein oder nutze das Farbrad.";
                HexColorBox.Focus();
                return;
            }

            if (hex != ToHex(_selection.ToRgb()))
                ApplyColorEdit(Color.Parse(hex).ToHsv());

            _draft = _draft with
            {
                GreetingName = GreetingNameBox.Text?.Trim() ?? "",
                FontName = (FontBox.SelectedItem as FontOption)?.Name
            };
            try
            {
                _save(_draft);
                Close(_draft);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                OptionsMessage.Text = "Die Einstellungen konnten nicht gespeichert werden.";
            }
        }

        private void OnResetClick(object? sender, RoutedEventArgs e)
        {
            _draft = AppearancePreferences.Default with
            {
                GreetingName = GreetingNameBox.Text?.Trim() ?? ""
            };

            _ready = false;
            FontBox.SelectedIndex = 0;
            _ready = true;
            SelectColorRow(_activeRow ?? PrimaryColorRow);
            PreviewAppearance();
        }

        private void OnCancelClick(object? sender, RoutedEventArgs e) => Close();

        private static string ToHex(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";

        private static (double Hue, double Saturation) WheelCoordinates(double x, double y) =>
            ((Math.Atan2(y, x) * 180 / Math.PI + 360) % 360,
                Math.Sqrt(x * x + y * y) / (WheelSize / 2.0));

        private static WriteableBitmap CreateWheel()
        {
            var bitmap = new WriteableBitmap(new PixelSize(WheelSize, WheelSize),
                new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Premul);
            var row = new byte[WheelSize * 4];
            using var buffer = bitmap.Lock();
            var center = WheelSize / 2.0 - 0.5;

            for (int y = 0; y < WheelSize; y++)
            {
                for (int x = 0; x < WheelSize; x++)
                {
                    var (hue, saturation) = WheelCoordinates(x - center, y - center);
                    var color = saturation <= 1
                        ? HsvColor.ToRgb(hue, saturation, 1, 1)
                        : Colors.Transparent;
                    int index = x * 4;
                    row[index] = color.A != 0 ? color.B : (byte)0;
                    row[index + 1] = color.A != 0 ? color.G : (byte)0;
                    row[index + 2] = color.A != 0 ? color.R : (byte)0;
                    row[index + 3] = color.A;
                }
                Marshal.Copy(row, 0, IntPtr.Add(buffer.Address, y * buffer.RowBytes), row.Length);
            }

            return bitmap;
        }

        private sealed record FontOption(string Label, string? Name)
        {
            public override string ToString() => Label;
        }
    }
}