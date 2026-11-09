using System.Drawing;
using System.Windows.Forms;

namespace RiotSwitcher.App;

/// <summary>Boîte de dialogue minimale pour renommer un compte.</summary>
internal sealed class PromptForm : Form
{
    private readonly TextBox _textBox;

    public string Value => _textBox.Text.Trim();

    public PromptForm(string title, string prompt, string initialValue)
    {
        Text = title;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = false;
        MaximizeBox = false;
        ShowInTaskbar = false;
        ClientSize = new Size(360, 120);
        Font = new Font("Segoe UI", 9F);
        AutoScaleMode = AutoScaleMode.Dpi;

        var label = new Label
        {
            Text = prompt,
            AutoSize = false,
            Location = new Point(12, 12),
            Size = new Size(336, 20)
        };

        _textBox = new TextBox
        {
            Text = initialValue,
            Location = new Point(12, 38),
            Width = 336,
            MaxLength = 60
        };

        var ok = new Button
        {
            Text = "OK",
            DialogResult = DialogResult.OK,
            Location = new Point(192, 78),
            Size = new Size(75, 26)
        };

        var cancel = new Button
        {
            Text = "Annuler",
            DialogResult = DialogResult.Cancel,
            Location = new Point(273, 78),
            Size = new Size(75, 26)
        };

        Controls.Add(label);
        Controls.Add(_textBox);
        Controls.Add(ok);
        Controls.Add(cancel);

        AcceptButton = ok;
        CancelButton = cancel;
        Shown += (_, _) =>
        {
            _textBox.Focus();
            _textBox.SelectAll();
        };
    }
}
