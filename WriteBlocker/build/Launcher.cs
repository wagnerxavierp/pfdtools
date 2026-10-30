using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace PfdWriteBlocker
{
    internal static class Program
    {
        [STAThread]
        private static int Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                string baseDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                if (string.IsNullOrEmpty(baseDir))
                {
                    ShowError("Não foi possível determinar o diretório do executável.");
                    return 1;
                }

                string guiScript = Path.Combine(baseDir, "PFD-WriteBlocker-GUI.ps1");
                string coreModule = Path.Combine(baseDir, "PFD-WriteBlocker.Core.psm1");

                if (!File.Exists(guiScript))
                {
                    ShowError(
                        "Arquivo não encontrado:\n" + guiScript +
                        "\n\nMantenha PFD-WriteBlocker.exe na mesma pasta que:\n" +
                        "  • PFD-WriteBlocker-GUI.ps1\n" +
                        "  • PFD-WriteBlocker.Core.psm1");
                    return 1;
                }

                if (!File.Exists(coreModule))
                {
                    ShowError(
                        "Módulo não encontrado:\n" + coreModule +
                        "\n\nO núcleo PFD-WriteBlocker.Core.psm1 é obrigatório.");
                    return 1;
                }

                string powershell = FindPowerShell();
                if (powershell == null)
                {
                    ShowError("powershell.exe não encontrado no sistema.");
                    return 1;
                }

                var psi = new ProcessStartInfo
                {
                    FileName = powershell,
                    Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + guiScript + "\"",
                    WorkingDirectory = baseDir,
                    UseShellExecute = false
                };

                using (Process proc = Process.Start(psi))
                {
                    if (proc == null)
                    {
                        ShowError("Falha ao iniciar o PowerShell.");
                        return 1;
                    }
                    proc.WaitForExit();
                    return proc.ExitCode;
                }
            }
            catch (Exception ex)
            {
                ShowError(ex.Message);
                return 1;
            }
        }

        private static string FindPowerShell()
        {
            string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string candidate = Path.Combine(systemRoot, "WindowsPowerShell", "v1.0", "powershell.exe");
            if (File.Exists(candidate))
                return candidate;

            string windir = Environment.GetEnvironmentVariable("WINDIR") ?? @"C:\Windows";
            candidate = Path.Combine(windir, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            if (File.Exists(candidate))
                return candidate;

            return null;
        }

        private static void ShowError(string message)
        {
            MessageBox.Show(
                message,
                "PFD WriteBlocker",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
