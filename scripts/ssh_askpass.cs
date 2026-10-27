using System;
using System.IO;
using System.Text;

// Build as an executable. OpenSSH captures its stdout; do not invoke it manually.
internal static class WindowsSshAskpass
{
    private static int Main()
    {
        try
        {
            if (!Console.IsOutputRedirected)
                return 2;
            string path = Environment.GetEnvironmentVariable("KING_SSH_PASSWORD_FILE");
            if (String.IsNullOrWhiteSpace(path))
                return 2;
            string[] lines = File.ReadAllLines(path, new UTF8Encoding(false, true));
            if (lines.Length != 1 || String.IsNullOrEmpty(lines[0]))
                return 2;
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.Out.WriteLine(lines[0]);
            Console.Out.Flush();
            return 0;
        }
        catch
        {
            // Never print exception details or the credential content.
            return 2;
        }
    }
}
