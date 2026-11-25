<#
    Instala Gestor IT como una aplicación más de Windows:
    - Copia la app a %LOCALAPPDATA%\Programs\GestorIT
    - Crea accesos directos con icono en el menú Inicio y en el escritorio
    - La abre para que puedas anclarla a la barra de tareas
    No necesita permisos de administrador. Tus servidores y la cuenta recordada no se tocan.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

try {
    $src  = $PSScriptRoot
    $dest = Join-Path $env:LOCALAPPDATA 'Programs\GestorIT'
    foreach ($f in 'GestorIT.ps1', 'GestorIT.ico') {
        if (-not (Test-Path (Join-Path $src $f))) { throw "Falta el archivo $f junto al instalador. Descomprime el ZIP entero antes de instalar." }
    }

    # Si la app está abierta, se cierra para poder sustituirla
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*GestorIT.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($f in 'GestorIT.ps1', 'GestorIT.ico', 'config.example.json') {
        if (Test-Path (Join-Path $src $f)) {
            Copy-Item (Join-Path $src $f) (Join-Path $dest $f) -Force
            Unblock-File (Join-Path $dest $f) -ErrorAction SilentlyContinue
        }
    }
    # Configuración: si traes un config.json junto al instalador, se instala (y sustituye al anterior).
    # Si no, se mantiene el que ya hubiera instalado. Sin config.json la app funciona con valores por defecto.
    if (Test-Path (Join-Path $src 'config.json')) { Copy-Item (Join-Path $src 'config.json') (Join-Path $dest 'config.json') -Force }

    # Para escribir el identificador de la app dentro del acceso directo
    if (-not ('GestorItLnk' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class GestorItLnk {
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr p;
        [FieldOffset(16)] public IntPtr pad;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out uint c);
        [PreserveSig] int GetAt(uint i, out PropertyKey k);
        [PreserveSig] int GetValue(ref PropertyKey k, out PropVariant v);
        [PreserveSig] int SetValue(ref PropertyKey k, ref PropVariant v);
        [PreserveSig] int Commit();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHGetPropertyStoreFromParsingName(string path, IntPtr pbc, int flags, ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    public static void SetAppId(string lnk, string id) {
        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        IPropertyStore st;
        SHGetPropertyStoreFromParsingName(lnk, IntPtr.Zero, 2, ref iid, out st);   // 2 = lectura y escritura
        PropertyKey key = new PropertyKey();
        key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");             // System.AppUserModel.ID
        key.pid = 5;
        PropVariant pv = new PropVariant();
        pv.vt = 31;                                                                 // VT_LPWSTR
        pv.p = Marshal.StringToCoTaskMemUni(id);
        try {
            Marshal.ThrowExceptionForHR(st.SetValue(ref key, ref pv));
            Marshal.ThrowExceptionForHR(st.Commit());
        } finally {
            Marshal.FreeCoTaskMem(pv.p);
            Marshal.ReleaseComObject(st);
        }
    }
}
'@
    }

    $ps1  = Join-Path $dest 'GestorIT.ps1'
    $ico  = Join-Path $dest 'GestorIT.ico'
    $exe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""
    $start = Join-Path ([Environment]::GetFolderPath('Programs')) 'Gestor IT.lnk'
    $desk  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Gestor IT.lnk'

    $wsh = New-Object -ComObject WScript.Shell
    $aumidOk = $true
    foreach ($lnkPath in $start, $desk) {
        $l = $wsh.CreateShortcut($lnkPath)
        $l.TargetPath = $exe
        $l.Arguments = $args
        $l.WorkingDirectory = $dest
        $l.IconLocation = "$ico,0"
        $l.WindowStyle = 1
        $l.Description = 'Servidores, equipos y usuarios del dominio'
        $l.Save()
        try { [GestorItLnk]::SetAppId($lnkPath, 'GestorIT.App') } catch { $aumidOk = $false }
    }

    # Quitar los accesos de la versión antigua del .bat, si los había
    Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'GestorIT.bat.lnk') -ErrorAction SilentlyContinue

    Start-Process -FilePath $start

    $msg = "Gestor IT está instalado y se está abriendo.`n`nPara anclarlo: clic derecho en su icono de la barra de tareas > Anclar a la barra de tareas.`n`nTambién lo tienes en el menú Inicio y en el escritorio."
    if (-not $aumidOk) { $msg += "`n`nAviso: no se ha podido registrar el identificador de la app. Si al anclarlo ves dos iconos, ánclalo desde el menú Inicio (clic derecho en Gestor IT > Anclar a la barra de tareas)." }
    [Windows.MessageBox]::Show($msg, 'Gestor IT', 'OK', 'Information') | Out-Null
} catch {
    [Windows.MessageBox]::Show("No se ha podido instalar.`n`n$($_.Exception.Message)", 'Gestor IT', 'OK', 'Error') | Out-Null
}
