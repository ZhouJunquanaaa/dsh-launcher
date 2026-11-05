using System;
using System.Diagnostics;
using System.IO;
using System.Text;

/// <summary>
/// 无控制台入口：用 CreateNoWindow 启动 dsh-luncher.ps1，避免双击时闪出 PowerShell 窗口。
/// </summary>
internal static class Program
{
    private static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "dsh-luncher.ps1");
        if (!File.Exists(script))
        {
            return 2;
        }

        string pwsh = ResolvePwsh();
        if (pwsh == null)
        {
            return 3;
        }

        var arguments = new StringBuilder();
        arguments.Append("-NoProfile -ExecutionPolicy Bypass -File \"");
        arguments.Append(script);
        arguments.Append('"');
        foreach (string arg in args)
        {
            arguments.Append(' ').Append('"').Append(arg.Replace("\"", "\\\"")).Append('"');
        }

        var startInfo = new ProcessStartInfo(pwsh, arguments.ToString())
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = dir,
        };

        Process.Start(startInfo);
        return 0;
    }

    private static string ResolvePwsh()
    {
        string local = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"Microsoft\WindowsApps\pwsh.exe");
        if (File.Exists(local))
        {
            return local;
        }

        foreach (string root in new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        })
        {
            string candidate = Path.Combine(root, @"PowerShell\7\pwsh.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (string entry in path.Split(';'))
        {
            if (entry.Length == 0)
            {
                continue;
            }

            try
            {
                string candidate = Path.Combine(entry.Trim(), "pwsh.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch (ArgumentException)
            {
            }
        }

        return null;
    }
}
