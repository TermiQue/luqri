using System.Runtime.InteropServices;
using System.Text;

namespace Luqri;

internal static class LanguageDetection
{
    internal static string? Detect(string sample)
    {
        if (string.IsNullOrWhiteSpace(sample)) return null;
        sample = sample.Normalize(NormalizationForm.FormC);
        var options = new EnumerationOptions
        {
            Size = (nuint)Marshal.SizeOf<EnumerationOptions>(),
            Category = "Language Detection"
        };
        if (MappingGetServices(ref options, out var services, out var count) != 0) return null;
        try
        {
            if (count == 0) return null;
            var bag = new PropertyBag { Size = (nuint)Marshal.SizeOf<PropertyBag>() };
            if (MappingRecognizeText(services, sample, (uint)sample.Length, 0, 0, ref bag) != 0) return null;
            try
            {
                if (bag.Count == 0 || bag.Ranges == 0) return null;
                var range = Marshal.PtrToStructure<DataRange>(bag.Ranges);
                // The first entry in the null-delimited list is the most probable language.
                return range.Data != 0 ? Marshal.PtrToStringUni(range.Data) : null;
            }
            finally { MappingFreePropertyBag(ref bag); }
        }
        finally { MappingFreeServices(services); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct EnumerationOptions
    {
        public nuint Size;
        [MarshalAs(UnmanagedType.LPWStr)] public string Category;
        public nint InputLanguage, OutputLanguage, InputScript, OutputScript, InputContentType, OutputContentType, Guid;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyBag
    {
        public nuint Size;
        public nint Ranges;
        public uint Count;
        public nint ServiceData;
        public uint ServiceDataSize;
        public nint CallerData;
        public uint CallerDataSize;
        public nint Context;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataRange
    {
        public uint Start, End;
        public nint Description;
        public uint DescriptionLength;
        public nint Data;
        public uint DataSize;
        public nint ContentType, ActionIds;
        public uint ActionCount;
        public nint ActionDisplayNames;
    }

    [DllImport("elscore")] private static extern int MappingGetServices(ref EnumerationOptions options, out nint services, out uint count);
    [DllImport("elscore")] private static extern int MappingFreeServices(nint services);
    [DllImport("elscore", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int MappingRecognizeText(nint service, string input, uint length, uint index, nint options, ref PropertyBag bag);
    [DllImport("elscore")] private static extern int MappingFreePropertyBag(ref PropertyBag bag);
}
