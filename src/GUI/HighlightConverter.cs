using System;
using System.Globalization;
using System.Text.RegularExpressions;
using Avalonia.Controls.Documents;
using Avalonia.Data.Converters;
using Avalonia.Media;

namespace FileSearcherApp
{
    //Markiert den gefundenen Bereich
    public sealed class HighlightConverter : IValueConverter
    {
        public static readonly HighlightConverter Instance = new();

        private static readonly Regex Marked = new(@"\[([^\]]+)\]", RegexOptions.Compiled);

        public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        {
            var text = value as string ?? "";
            var inlines = new InlineCollection();
            var pos = 0;

            foreach (Match m in Marked.Matches(text))
            {
                if (m.Index > pos)
                    inlines.Add(new Run(text[pos..m.Index]));

                inlines.Add(new Run(m.Groups[1].Value)
                {
                    FontWeight = FontWeight.Bold,
                    Foreground = Brushes.Gold
                });
                pos = m.Index + m.Length;
            }

            if (pos < text.Length)
                inlines.Add(new Run(text[pos..]));

            return inlines;
        }

        public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
            => throw new NotSupportedException();
    }
}