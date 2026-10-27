using System;
using System.Linq;

namespace Review;

/// <summary>A hunk of a diff</summary>
public record Hunk(int NewStart, string[] Lines)
{
    public bool Contains(int line) => line >= NewStart && line < NewStart + Lines.Length;
}

public static class Program
{
    [Obsolete("use Contains")]
    public static async Task<int> Main(string[] args)
    {
        var hunk = new Hunk(12, "a\nb".Split('\n'));
        Console.WriteLine($"{hunk.Contains(13)} {args.Count(a => a.Length > 0)}");
        return await Task.FromResult(0);
    }
}
