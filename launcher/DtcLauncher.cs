// DTC.exe: a windowless starter for the Deployment Manager's system-tray app (launcher\DTC-Tray.ps1).
//
// Windows PowerShell is a console program: started from a shortcut it opens a console window (or a Windows Terminal tab),
// even with -WindowStyle Hidden. This program is a Windows (GUI) program that starts powershell.exe with CREATE_NO_WINDOW,
// so no window appears at all. It passes its own arguments on unchanged (for example -Mode choose, -Autostart) and exits.
//
// Built locally by lib\Launcher.psm1 (New-LauncherExe) with the C# compiler of the .NET Framework that is part of
// Windows; no download, no installer, no administrator rights. C# 5 syntax only (that compiler's language version).
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("DTC Deployment Manager")]
[assembly: System.Reflection.AssemblyDescription("Starts the DTC Deployment Manager in the system tray without a console window.")]
[assembly: System.Reflection.AssemblyProduct("DTC Deployment Manager")]

static class DtcLauncher
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string tray = Path.Combine(dir, "DTC-Tray.ps1");
        if (!File.Exists(tray))
        {
            Fail("DTC-Tray.ps1 was not found next to DTC.exe (" + dir + ").\n\nRun Setup-Launcher.cmd in the program folder again.");
            return 2;
        }
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps))
        {
            Fail("Windows PowerShell (" + ps + ") was not found. It is part of Windows 10 and 11; check that it has not been removed or blocked.");
            return 3;
        }
        StringBuilder line = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ");
        line.Append(Quote(tray));
        foreach (string a in args) { line.Append(' ').Append(Quote(a)); }
        ProcessStartInfo psi = new ProcessStartInfo(ps, line.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = Path.GetDirectoryName(dir.TrimEnd('\\'));
        try
        {
            Process.Start(psi);
            return 0;
        }
        catch (Exception e)
        {
            Fail("The Deployment Manager could not be started: " + e.Message);
            return 1;
        }
    }

    static void Fail(string message)
    {
        MessageBox.Show(message, "DTC Deployment Manager", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    // Quotes one argument for CommandLineToArgvW (the rules powershell.exe uses to split its command line).
    static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) { return arg; }
        StringBuilder sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { sb.Append('\\', slashes * 2 + 1); }
            else { sb.Append('\\', slashes); }
            slashes = 0;
            sb.Append(c);
        }
        sb.Append('\\', slashes * 2);
        sb.Append('"');
        return sb.ToString();
    }
}
