using System.Globalization;

namespace RiotSwitcher.Core.Updates;

/// <summary>Version SemVer simple utilisée par les tags de release (v1.2.3).</summary>
public readonly struct UpdateVersion : IEquatable<UpdateVersion>, IComparable<UpdateVersion>
{
    public UpdateVersion(int major, int minor, int patch)
    {
        if (major < 0) throw new ArgumentOutOfRangeException(nameof(major));
        if (minor < 0) throw new ArgumentOutOfRangeException(nameof(minor));
        if (patch < 0) throw new ArgumentOutOfRangeException(nameof(patch));

        Major = major;
        Minor = minor;
        Patch = patch;
    }

    public int Major { get; }
    public int Minor { get; }
    public int Patch { get; }

    public static UpdateVersion Current => Parse(AppInfo.Version);

    public static bool TryParse(string? value, out UpdateVersion version)
    {
        version = default;

        if (string.IsNullOrWhiteSpace(value)) return false;

        var text = value.Trim();
        if (text.StartsWith('v') || text.StartsWith('V')) text = text[1..];

        var parts = text.Split('.');
        if (parts.Length != 3) return false;

        if (!int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var major) ||
            !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var minor) ||
            !int.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out var patch))
        {
            return false;
        }

        version = new UpdateVersion(major, minor, patch);
        return true;
    }

    public static UpdateVersion Parse(string value) =>
        TryParse(value, out var version)
            ? version
            : throw new FormatException($"Version invalide : « {value} » (format attendu : 1.2.3 ou v1.2.3).");

    public int CompareTo(UpdateVersion other)
    {
        var major = Major.CompareTo(other.Major);
        if (major != 0) return major;

        var minor = Minor.CompareTo(other.Minor);
        if (minor != 0) return minor;

        return Patch.CompareTo(other.Patch);
    }

    public bool Equals(UpdateVersion other) =>
        Major == other.Major && Minor == other.Minor && Patch == other.Patch;

    public override bool Equals(object? obj) => obj is UpdateVersion other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(Major, Minor, Patch);

    public override string ToString() =>
        string.Create(CultureInfo.InvariantCulture, $"{Major}.{Minor}.{Patch}");

    public static bool operator ==(UpdateVersion left, UpdateVersion right) => left.Equals(right);
    public static bool operator !=(UpdateVersion left, UpdateVersion right) => !left.Equals(right);
    public static bool operator <(UpdateVersion left, UpdateVersion right) => left.CompareTo(right) < 0;
    public static bool operator >(UpdateVersion left, UpdateVersion right) => left.CompareTo(right) > 0;
    public static bool operator <=(UpdateVersion left, UpdateVersion right) => left.CompareTo(right) <= 0;
    public static bool operator >=(UpdateVersion left, UpdateVersion right) => left.CompareTo(right) >= 0;
}
