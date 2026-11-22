using System;
using System.Globalization;
using System.IO;
using System.Text.Json;
using Avalonia.Interactivity;
using Avalonia.Media;

namespace FileSearcherApp
{
    public partial class MainWindow
    {
        private static readonly string AppearancePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FileSearcherApp", "appearance.json");

        private readonly SolidColorBrush _primaryBrush = new();
        private readonly SolidColorBrush _secondaryBrush = new();
        private readonly SolidColorBrush _textBrush = new();
        private readonly SolidColorBrush _iconBrush = new();
        private readonly SolidColorBrush _shadeBrush = new();
        private readonly SolidColorBrush _hoverBrush = new();
        private readonly SolidColorBrush _borderBrush = new();

        private AppearancePreferences _appearance = AppearancePreferences.Default;

        private void InitializeAppearance()
        {
            RegisterBrush(_primaryBrush, "ThemePrimaryBrush");
            RegisterBrush(_secondaryBrush, "ThemeSecondaryBrush", "ButtonBackground",
                "TextControlBackground", "TextControlBackgroundFocused", "ComboBoxBackground",
                "ExpanderHeaderBackground");
            RegisterBrush(_textBrush, "ThemeTextBrush", "TextControlForeground",
                "TextControlForegroundFocused", "TextControlForegroundPointerOver",
                "ButtonForeground", "ButtonForegroundPointerOver", "ButtonForegroundPressed",
                "ComboBoxForeground", "ComboBoxForegroundFocused", "ComboBoxItemForeground",
                "ComboBoxItemForegroundPointerOver", "ComboBoxItemForegroundPressed",
                "ExpanderHeaderForeground", "ExpanderHeaderForegroundPointerOver",
                "ExpanderHeaderForegroundPressed");
            RegisterBrush(_iconBrush, "ThemeIconBrush", "TextControlPlaceholderForeground",
                "TextControlPlaceholderForegroundFocused", "TextControlPlaceholderForegroundPointerOver",
                "ComboBoxDropDownGlyphForeground", "ComboBoxDropDownGlyphForegroundFocused",
                "ComboBoxDropDownGlyphForegroundFocusedPressed");
            RegisterBrush(_shadeBrush, "ThemeShadeBrush", "ButtonBackgroundPressed",
                "ComboBoxBackgroundPressed", "ComboBoxDropDownBackground", "ComboBoxItemBackgroundPressed",
                "ExpanderHeaderBackgroundPressed", "ExpanderContentBackground");
            RegisterBrush(_hoverBrush, "ButtonBackgroundPointerOver", "TextControlBackgroundPointerOver",
                "ComboBoxBackgroundPointerOver", "ComboBoxItemBackgroundPointerOver",
                "ExpanderHeaderBackgroundPointerOver");
            RegisterBrush(_borderBrush, "ThemeBorderBrush", "ButtonBorderBrushPointerOver",
                "ButtonBorderBrushPressed", "TextControlBorderBrushFocused",
                "TextControlBorderBrushPointerOver", "ComboBoxBorderBrushPointerOver",
                "ComboBoxBorderBrushPressed", "ComboBoxDropDownBorderBrush",
                "ExpanderContentBorderBrush", "ExpanderHeaderBorderBrush",
                "ExpanderHeaderBorderBrushPointerOver", "ExpanderHeaderBorderBrushPressed");

            _appearance = LoadAppearance();
            ApplyAppearance(_appearance);
        }

        private void RegisterBrush(IBrush brush, params string[] keys)
        {
            foreach (var key in keys)
                Resources[key] = brush;
        }

        private async void OnOptionsClick(object? sender, RoutedEventArgs e)
        {
            var dialog = new AppearanceWindow(_appearance, Resources, ApplyAppearance, SaveAppearance);
            try
            {
                var saved = await dialog.ShowDialog<AppearancePreferences?>(this);
                if (saved is not null)
                    _appearance = saved;
            }
            finally
            {
                ApplyAppearance(_appearance);
            }
        }

        private void ApplyAppearance(AppearancePreferences appearance)
        {
            var primary = Color.Parse(appearance.PrimaryColor);
            var secondary = Color.Parse(appearance.SecondaryColor);
            var text = Color.Parse(appearance.TextColor);
            _primaryBrush.Color = primary;
            _secondaryBrush.Color = secondary;
            _textBrush.Color = text;
            _iconBrush.Color = appearance.PrimaryColor == AppearancePreferences.Default.PrimaryColor &&
                appearance.TextColor == AppearancePreferences.Default.TextColor
                ? Color.FromRgb(138, 171, 170)
                : Mix(text, primary, 0.32);
            _borderBrush.Color = Mix(primary, text, 0.28);
            _hoverBrush.Color = Mix(primary, text, 0.08);
            _shadeBrush.Color = Mix(secondary, primary, 0.45);

            FontFamily = appearance.FontName is { Length: > 0 } name
                ? new FontFamily(name)
                : FontFamily.Default;

            WelcomeText.Text = string.IsNullOrEmpty(appearance.GreetingName)
                ? "Hallo!"
                : $"Hallo {appearance.GreetingName}!";
        }

        private static Color Mix(Color first, Color second, double weight)
        {
            byte Channel(byte from, byte to) => (byte)Math.Round(from + (to - from) * weight);
            return Color.FromRgb(Channel(first.R, second.R), Channel(first.G, second.G), Channel(first.B, second.B));
        }

        private static AppearancePreferences LoadAppearance()
        {
            try
            {
                if (File.Exists(AppearancePath))
                {
                    var saved = JsonSerializer.Deserialize<AppearancePreferences>(File.ReadAllText(AppearancePath));
                    if (saved is not null)
                    {
                        return new AppearancePreferences(
                            AppearancePreferences.TryNormalizeColor(saved.PrimaryColor, out var primary) ? primary : AppearancePreferences.Default.PrimaryColor,
                            AppearancePreferences.TryNormalizeColor(saved.SecondaryColor, out var secondary) ? secondary : AppearancePreferences.Default.SecondaryColor,
                            AppearancePreferences.TryNormalizeColor(saved.TextColor, out var text) ? text : AppearancePreferences.Default.TextColor,
                            saved.GreetingName?.Trim() ?? AppearancePreferences.Default.GreetingName,
                            saved.FontName?.Trim());
                    }
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
            {
                // Die Oberfläche kann auch mit einer unlesbaren Einstellungsdatei starten.
            }

            return AppearancePreferences.Default;
        }

        private static void SaveAppearance(AppearancePreferences appearance)
        {
            var directory = Path.GetDirectoryName(AppearancePath)!;
            Directory.CreateDirectory(directory);
            var temporaryPath = Path.Combine(directory, Path.GetRandomFileName());
            try
            {
                File.WriteAllText(temporaryPath, JsonSerializer.Serialize(appearance));
                File.Move(temporaryPath, AppearancePath, overwrite: true);
            }
            finally
            {
                File.Delete(temporaryPath);
            }
        }
    }

    internal sealed record AppearancePreferences(
        string PrimaryColor, string SecondaryColor, string TextColor, string GreetingName,
        string? FontName = null)
    {
        internal static AppearancePreferences Default { get; } =
            new("#0C3835", "#001816", "#C9DDDC", Environment.UserName);

        internal static bool TryNormalizeColor(string? input, out string normalized)
        {
            normalized = "";
            var digits = input?.Trim() ?? "";
            if (digits.StartsWith('#'))
                digits = digits[1..];

            if (digits.Length != 6 ||
                !uint.TryParse(digits, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var rgb))
            {
                return false;
            }

            normalized = $"#{rgb:X6}";
            return true;
        }
    }
}