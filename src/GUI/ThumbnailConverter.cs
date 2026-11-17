using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using Avalonia.Data.Converters;
using Avalonia.Media.Imaging;

namespace FileSearcherApp
{
    /// <summary>Pfad einer Bilddatei → verkleinertes Vorschaubild (sonst null).</summary>
    public sealed class ThumbnailConverter : IValueConverter
    {
        public static readonly ThumbnailConverter Instance = new();

        private static readonly HashSet<string> ImageExtensions =
            new(StringComparer.OrdinalIgnoreCase)
            { ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp", ".ico" };

        private const int ThumbWidth = 320;   // Breite des Vorschaubilds in Pixeln
        private const int CacheSize = 50;     // so viele Vorschaubilder merken wir uns

        private static readonly Dictionary<string, Bitmap> Cache = new();
        private static readonly Queue<string> Order = new();

        public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        {
            if (value is not string path || !IsImagePath(path))
            return null;

            if (Cache.TryGetValue(path, out var cached))
                return cached;

            try
            {
                if (!File.Exists(path)) return null;

                using var stream = File.OpenRead(path);
                var bitmap = Bitmap.DecodeToWidth(stream, ThumbWidth, BitmapInterpolationMode.MediumQuality);

                Cache[path] = bitmap;
                Order.Enqueue(path);
                if (Order.Count > CacheSize)
                    Cache.Remove(Order.Dequeue());

                return bitmap;
            }
            catch
            {
                return null;   // defekte oder gesperrte Datei: einfach kein Bild
            }
        }

        public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
            => throw new NotSupportedException();

        public static bool IsImagePath(string? path) =>
        path is not null && ImageExtensions.Contains(Path.GetExtension(path));
    }

       public static class FileTypeConverters
        {
            // true, wenn der Pfad KEINE Bilddatei ist
            public static readonly FuncValueConverter<string?, bool> IsNotImage =
                new(path => !ThumbnailConverter.IsImagePath(path));
        }
}