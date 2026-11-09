using System.Drawing;
using System.Windows.Forms;

namespace RiotSwitcher.App;

/// <summary>Icône de l'application, extraite de l'exécutable (ressource Win32).</summary>
internal static class AppIcon
{
    private static Icon? _cached;

    public static Icon Get()
    {
        if (_cached is not null)
        {
            return _cached;
        }

        try
        {
            var icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            if (icon is not null)
            {
                _cached = icon;
                return _cached;
            }
        }
        catch
        {
            // icône par défaut si l'extraction échoue
        }

        _cached = SystemIcons.Application;
        return _cached;
    }
}
