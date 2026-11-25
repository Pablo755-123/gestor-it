<#
    Gestor IT
    Servidores (RDP, SSH y PowerShell remoto), equipos y usuarios del Directorio Activo,
    y pantallas de dashboard (kioscos) en una sola app de escritorio para Windows.
    PowerShell + WPF. No necesita RSAT ni instalar nada en los servidores.

    - La configuración de tu red va en config.json, junto a este archivo (ver config.example.json).
    - Tus servidores y la cuenta recordada se guardan en %APPDATA%\GestorIT.
    - No guarda contraseñas en claro: las de RDP las gestiona Windows y la del dominio se cifra con DPAPI.

    Ejecútalo con Instalar.bat (recomendado) o:
        powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\GestorIT.ps1

    Licencia MIT. Ver LICENSE.
#>

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# Si algo falla al arrancar, se avisa y se guarda en un log en vez de cerrarse sin decir nada
$ErrorLog = Join-Path $env:APPDATA 'GestorIT\error.log'
trap {
    $msg = "$($_.Exception.Message)`n`nLínea $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $ErrorLog) | Out-Null
        Add-Content -Path $ErrorLog -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}`r`n" -f (Get-Date), $msg)
    } catch { }
    [Windows.MessageBox]::Show("Gestor IT no ha podido arrancar.`n`n$msg`n`nSe ha guardado en $ErrorLog", 'Gestor IT', 'OK', 'Error') | Out-Null
    [Environment]::Exit(1)
}

# Identidad propia en la barra de tareas: así la ventana se agrupa con el acceso directo anclado
# y no aparece como "Windows PowerShell"
try {
    if (-not ('GestorItShell' -as [type])) {
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class GestorItShell { [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id); }'
    }
    [void][GestorItShell]::SetCurrentProcessExplicitAppUserModelID('GestorIT.App')
} catch { }
Add-Type -AssemblyName System.DirectoryServices, System.DirectoryServices.AccountManagement

if (-not ('AdComputer' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;

public static class Txt {
    public static string Rel(DateTime? d) {
        if (!d.HasValue) return "Nunca";
        double days = (DateTime.Now - d.Value).TotalDays;
        if (days < 1) return "Hoy";
        if (days < 2) return "Ayer";
        if (days < 31) return "Hace " + (int)days + " días";
        return d.Value.ToString("dd/MM/yyyy");
    }
    public static string D(string s) { return string.IsNullOrEmpty(s) ? "—" : s; }
    public static string F(DateTime? d) { return d.HasValue ? d.Value.ToString("dd/MM/yyyy HH:mm") : "—"; }
}

public class RdpServer : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void N(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }

    string _id = Guid.NewGuid().ToString("N"), _name = "", _host = "", _user = "",
           _group = "General", _notes = "", _status = "unknown", _last = "";
    int _port = 3389;
    bool _fs = true, _mm = false, _admin = false;
    string _proto = "rdp";
    public string Protocol { get { return _proto; } set { _proto = (value == "ssh") ? "ssh" : "rdp"; N("Protocol"); N("IsSsh"); N("ProtoLabel"); N("Address"); } }
    public bool   IsSsh      { get { return _proto == "ssh"; } }
    public string ProtoLabel { get { return _proto == "ssh" ? "SSH" : "RDP"; } }
    public int    DefaultPort { get { return _proto == "ssh" ? 22 : 3389; } }

    public string Id         { get { return _id; }     set { _id = value; N("Id"); } }
    public string Name       { get { return _name; }   set { _name = value; N("Name"); } }
    public string Host       { get { return _host; }   set { _host = value; N("Host"); N("Address"); } }
    public int    Port       { get { return _port; }   set { _port = value; N("Port"); N("Address"); } }
    public string User       { get { return _user; }   set { _user = value; N("User"); N("UserDisplay"); } }
    public string Group      { get { return _group; }  set { _group = value; N("Group"); } }
    public string Notes      { get { return _notes; }  set { _notes = value; N("Notes"); N("HasNotes"); } }
    public bool   FullScreen { get { return _fs; }     set { _fs = value; N("FullScreen"); } }
    public bool   MultiMon   { get { return _mm; }     set { _mm = value; N("MultiMon"); } }
    public bool   Admin      { get { return _admin; }  set { _admin = value; N("Admin"); } }
    public string Status     { get { return _status; } set { _status = value; N("Status"); } }
    public string LastConnected { get { return _last; } set { _last = value; N("LastConnected"); N("LastDisplay"); } }

    public string Address     { get { return _port == DefaultPort ? _host : _host + ":" + _port; } }
    public string UserDisplay { get { return string.IsNullOrEmpty(_user) ? "Usuario al conectar" : _user; } }
    public bool   HasNotes    { get { return !string.IsNullOrEmpty(_notes); } }
    public string LastDisplay { get { return string.IsNullOrEmpty(_last) ? "Nunca conectado" : "Última vez: " + _last; } }
}

public class AdComputer : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void N(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
    string _status = "unknown", _sstate = "unknown", _suser = "", _serr = "";
    public string SessionState { get { return _sstate; } set { _sstate = value; N("SessionState"); N("SessionText"); N("SessionTip"); } }
    public string SessionUser  { get { return _suser; }  set { _suser = value ?? ""; N("SessionUser"); N("SessionText"); N("SessionTip"); } }
    public string SessionError { get { return _serr; }   set { _serr = value ?? ""; N("SessionError"); N("SessionTip"); } }
    public string SessionText { get {
        switch (_sstate) {
            case "user":
                string[] parts = _suser.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
                for (int i = 0; i < parts.Length; i++) { string x = parts[i].Trim(); int k = x.LastIndexOf('\\'); parts[i] = k >= 0 ? x.Substring(k + 1) : x; }
                return string.Join(", ", parts);
            case "nobody":      return "Nadie";
            case "unreachable": return "Sin acceso";
            case "error":       return "No disponible";
            case "checking":    return "Buscando…";
            default:            return "";
        } } }
    public string SessionTip { get {
        switch (_sstate) {
            case "user":        return _suser;
            case "error":       return _serr;
            case "unreachable": return "Apagado, o su firewall no deja consultarlo (RPC, puerto 135)";
            default:            return null;
        } } }
    public string Name { get; set; }
    public string Host { get; set; }
    public string Os { get; set; }
    public string Family { get; set; }
    public string Description { get; set; }
    public string Dn { get; set; }
    public bool Enabled { get; set; }
    public DateTime? LastLogon { get; set; }
    public int Port { get { return 3389; } }
    public string Status { get { return _status; } set { _status = value; var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs("Status")); } }
    public string Subtitle { get {
        string s = string.IsNullOrEmpty(Os) ? "Sistema desconocido" : Os;
        if (Retired) s = "Retirado" + (RetiredOn.HasValue ? " el " + RetiredOn.Value.ToString("dd/MM/yyyy") : "") + ", " + s;
        else if (!Enabled) s = "Deshabilitado, " + s;
        return string.IsNullOrEmpty(Description) ? s : s + ", " + Description; } }
    public bool Retired { get; set; }
    public DateTime? RetiredOn { get; set; }
    public string RetiredBy { get; set; }
    public string Origin { get; set; }
    public bool Inactive { get { return Enabled && !Retired && (!LastLogon.HasValue || (DateTime.Now - LastLogon.Value).TotalDays > 90); } }
    public int RetiredDays { get { return RetiredOn.HasValue ? (int)(DateTime.Now - RetiredOn.Value).TotalDays : 0; } }
    public bool RetiredLong { get { return Retired && RetiredOn.HasValue && RetiredDays >= 30; } }
    public string LastLogonText { get { return Txt.Rel(LastLogon); } }
}

public class AdUser : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    public void NotifyAll() { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(string.Empty)); }

    public string Sam { get; set; }
    public string Name { get; set; }
    public string Mail { get; set; }
    public string Department { get; set; }
    public string Title { get; set; }
    public string Description { get; set; }
    public string Phone { get; set; }
    public string Dn { get; set; }
    public bool Enabled { get; set; }
    public bool Locked { get; set; }
    public bool PwdExpired { get; set; }
    public bool PwdNeverExpires { get; set; }
    public bool PwdMustChange { get; set; }
    public DateTime? LastLogon { get; set; }
    public DateTime? PwdLastSet { get; set; }
    public DateTime? PwdExpires { get; set; }
    public DateTime? Created { get; set; }
    public string[] Groups { get; set; }
    public string[] GroupDns { get; set; }
    public string SessionOn { get; set; }
    public string SessionText { get { return string.IsNullOrEmpty(SessionOn) ? "—" : SessionOn; } }

    public string StatusKey { get {
        if (!Enabled) return "disabled";
        if (Locked) return "locked";
        if (PwdExpired) return "expired";
        return "active"; } }
    public string StatusText { get {
        switch (StatusKey) {
            case "disabled": return "Deshabilitada";
            case "locked":   return "Bloqueada";
            case "expired":  return "Contraseña caducada";
            default:         return "Activa";
        } } }
    public bool Inactive { get { return Enabled && (!LastLogon.HasValue || (DateTime.Now - LastLogon.Value).TotalDays > 90); } }
    public string Initials { get {
        string n = string.IsNullOrEmpty(Name) ? (Sam ?? "") : Name;
        string[] parts = n.Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length >= 2) return (parts[0].Substring(0, 1) + parts[1].Substring(0, 1)).ToUpper();
        return n.Substring(0, Math.Min(2, n.Length)).ToUpper(); } }
    public string Subtitle        { get { return string.IsNullOrEmpty(Department) ? Sam : Sam + ", " + Department; } }
    public string LastLogonText   { get { return Txt.Rel(LastLogon); } }
    public string MailText        { get { return Txt.D(Mail); } }
    public string TitleText       { get { return Txt.D(Title); } }
    public string DepartmentText  { get { return Txt.D(Department); } }
    public string PhoneText       { get { return Txt.D(Phone); } }
    public string DescriptionText { get { return Txt.D(Description); } }
    public string LastLogonFull   { get { return LastLogon.HasValue ? Txt.F(LastLogon) : "Nunca"; } }
    public string PwdLastSetText  { get { return PwdMustChange ? "Tiene que cambiarla al entrar" : Txt.F(PwdLastSet); } }
    public string PwdExpiresText  { get { return PwdNeverExpires ? "No caduca" : Txt.F(PwdExpires); } }
    public string CreatedText     { get { return Txt.F(Created); } }
    public string ToggleText      { get { return Enabled ? "Deshabilitar" : "Habilitar"; } }
    public int    GroupCount      { get { return Groups == null ? 0 : Groups.Length; } }
    public string GroupsTitle     { get { return "Grupos (" + GroupCount + ")"; } }
}

public class BufferPc : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    public void NotifyAll() { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(string.Empty)); }
    public BufferPc() { Estado = "unknown"; Detalle = "Sin revisar"; }
    public static string AppName = "dashboard";
    public string AppLabel { get { return AppName; } }
    public string AppTip   { get { return "Cierra " + AppName + " y lo vuelve a abrir en la pantalla"; } }
    public string Name { get; set; }
    public string Host { get; set; }
    public string Estado { get; set; }      // ok, nosp, locked, nosession, off, noaccess, checking, busy, unknown
    public string User { get; set; }
    public string Detalle { get; set; }
    public DateTime? SpSince { get; set; }
    public DateTime? Boot { get; set; }
    public string SpPath { get; set; }
    public string SpArgs { get; set; }
    public string SpDir { get; set; }
    public string SpUser { get; set; }
    public bool Busy { get; set; }

    public string EstadoText { get {
        switch (Estado) {
            case "ok":        return "Operativo";
            case "nosp":      return "Sin " + AppName;
            case "locked":    return "Bloqueado";
            case "nosession": return "Sin sesión";
            case "off":       return "Apagado";
            case "noaccess":  return "Sin acceso";
            case "checking":  return "Revisando…";
            case "busy":      return "Reiniciando…";
            default:          return "Sin revisar";
        } } }
    // Reutiliza los colores de las píldoras de usuarios: active verde, expired ámbar, locked rojo, disabled gris
    public string StatusKey { get {
        switch (Estado) {
            case "ok":        return "active";
            case "nosp": case "locked": case "nosession": return "expired";
            case "off":       return "locked";
            default:          return "disabled";
        } } }
    public bool IsProblem   { get { return Estado != "ok" && Estado != "checking" && Estado != "busy" && Estado != "unknown"; } }
    public string SpSinceText { get { return SpSince.HasValue ? SpSince.Value.ToString("dd/MM HH:mm") : "—"; } }
    public string UptimeText { get {
        if (!Boot.HasValue) return "—";
        TimeSpan d = DateTime.Now - Boot.Value;
        if (d.TotalDays >= 1) return (int)Math.Floor(d.TotalDays) + " d " + d.Hours + " h";
        return d.Hours + " h " + d.Minutes + " min"; } }
    public bool LongUptime  { get { return Boot.HasValue && (DateTime.Now - Boot.Value).TotalDays > 14; } }
    public string UserText  { get { return string.IsNullOrEmpty(User) ? "—" : User; } }
    public bool CanRestartSp { get { return !Busy && !string.IsNullOrEmpty(SpPath) && (Estado == "ok" || Estado == "nosp" || Estado == "locked"); } }
    public bool CanReboot    { get { return !Busy && Estado != "off" && Estado != "checking" && Estado != "unknown"; } }
}

public class InfoRow {
    public string Key { get; set; }
    public string Value { get; set; }
    public bool Strong { get; set; }
}

public class NavItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    int _c;
    public string Section { get; set; }
    public string Key { get; set; }
    public string Name { get; set; }
    public string Title { get; set; }
    public int Count { get { return _c; } set { _c = value; var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs("Count")); } }
}
'@
}

# ---------------------------------------------------------------- Rutas
# ---------------------------------------------------------------- Configuración (config.json)
$Cfg = $null
foreach ($cf in @(Join-Path $PSScriptRoot 'config.json')) {
    if (Test-Path $cf) {
        try { $Cfg = [IO.File]::ReadAllText($cf, [Text.Encoding]::UTF8) | ConvertFrom-Json; break }
        catch { [Windows.MessageBox]::Show("El archivo $cf no es un JSON válido.`n`n$($_.Exception.Message)", 'Gestor IT', 'OK', 'Warning') | Out-Null }
    }
}
function Get-Cfg([string]$path, $default) {
    $v = $Cfg
    foreach ($k in ($path -split '\.')) { if ($null -eq $v) { break }; $v = $v.$k }
    if ($null -eq $v -or ($v -is [string] -and $v -eq '')) { $default } else { $v }
}
$CfgController = [string](Get-Cfg 'DefaultController' '')       # dominio o IP del controlador para conectar sin sesión de dominio
$CfgNetBox     = ([string](Get-Cfg 'NetBoxUrl' '')).TrimEnd('/')  # vacío = sin botón de NetBox
$KioskOn       = [bool](Get-Cfg 'Kiosks.Enabled' $false)
$KioskTitle    = [string](Get-Cfg 'Kiosks.Title' 'Pantallas')
$KioskPrefix   = [string](Get-Cfg 'Kiosks.Prefix' 'KIOSK-')
$KioskProgram  = [string](Get-Cfg 'Kiosks.Program' 'Dashboard.exe')
$KioskApp      = [string](Get-Cfg 'Kiosks.AppName' 'Dashboard')
$KioskServer   = [string](Get-Cfg 'Kiosks.Server' '')

$DataDir  = Join-Path $env:APPDATA ([string](Get-Cfg 'DataFolder' 'GestorIT'))
$DataFile = Join-Path $DataDir 'servidores.json'
$TempDir  = Join-Path $env:TEMP 'GestorIT'
New-Item -ItemType Directory -Force -Path $DataDir, $TempDir | Out-Null

# ---------------------------------------------------------------- Interfaz
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Gestor IT" Width="1340" Height="820" MinWidth="1080" MinHeight="600"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanResizeWithGrip" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI Variable Text, Segoe UI" Foreground="#E4E7EC" FontSize="13"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="Mono">Cascadia Mono, Consolas</FontFamily>

    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#A3ACB9"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="ColHead" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#7D8796"/>
    </Style>
    <Style x:Key="Key" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#7D8796"/>
      <Setter Property="Margin" Value="0,0,0,9"/>
    </Style>
    <Style x:Key="Val" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#E4E7EC"/>
      <Setter Property="Margin" Value="0,0,0,9"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,22,0,12"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E4E7EC"/>
      <Setter Property="Background" Value="#20262F"/>
      <Setter Property="BorderBrush" Value="#2E3540"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="7">
              <Grid>
                <Border x:Name="ov" Background="#FFFFFF" Opacity="0" CornerRadius="6"/>
                <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ov" Property="Opacity" Value="0.07"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ov" Property="Opacity" Value="0.15"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#F2B84B"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#F2B84B"/>
      <Setter Property="BorderBrush" Value="#F2B84B"/>
      <Setter Property="Foreground" Value="#1C1608"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BtnGhost" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="#A3ACB9"/>
      <Setter Property="Padding" Value="9,7"/>
    </Style>

    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Foreground" Value="#A3ACB9"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#232932"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="WinClose" TargetType="Button" BasedOn="{StaticResource WinBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="0,11,0,0"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#C42B1C"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="#12151A"/>
      <Setter Property="Foreground" Value="#E4E7EC"/>
      <Setter Property="CaretBrush" Value="#F2B84B"/>
      <Setter Property="SelectionBrush" Value="#F2B84B"/>
      <Setter Property="BorderBrush" Value="#2E3540"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#3A4250"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#F2B84B"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PassInput" TargetType="PasswordBox">
      <Setter Property="Background" Value="#12151A"/>
      <Setter Property="Foreground" Value="#E4E7EC"/>
      <Setter Property="CaretBrush" Value="#F2B84B"/>
      <Setter Property="SelectionBrush" Value="#F2B84B"/>
      <Setter Property="BorderBrush" Value="#2E3540"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#F2B84B"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E4E7EC"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="track" Width="38" Height="20" CornerRadius="10" Background="#2A313B" BorderBrush="#3A4250" BorderThickness="1">
                <Ellipse x:Name="knob" Width="12" Height="12" Fill="#A3ACB9" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#F2B84B"/>
                <Setter TargetName="track" Property="BorderBrush" Value="#F2B84B"/>
                <Setter TargetName="knob" Property="Fill" Value="#1C1608"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="track" Property="BorderBrush" Value="#FFD98A"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Listas de la barra lateral: sin ScrollViewer propio para que la rueda del ratón llegue al panel -->
    <Style x:Key="NavList" TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBox"><ItemsPresenter/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavItem" TargetType="ListBoxItem">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Grid Margin="0,1" Cursor="Hand">
              <Border x:Name="b" Background="Transparent" CornerRadius="7" Padding="12,8"><ContentPresenter/></Border>
              <Border x:Name="mark" Width="3" CornerRadius="2" Background="#F2B84B" HorizontalAlignment="Left" Margin="0,8" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1B2027"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="#20262F"/>
                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <DataTemplate x:Key="NavTemplate">
      <DockPanel>
        <TextBlock DockPanel.Dock="Right" Text="{Binding Count}" FontSize="12" Foreground="#7D8796" VerticalAlignment="Center"/>
        <TextBlock Text="{Binding Name}" FontSize="13" Foreground="#E4E7EC" TextTrimming="CharacterEllipsis" Margin="0,0,8,0"/>
      </DockPanel>
    </DataTemplate>

    <Style x:Key="RowItem" TargetType="ListBoxItem">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Grid Margin="0,1" Cursor="Hand">
              <Border x:Name="b" Background="Transparent" CornerRadius="7" Padding="14,8"><ContentPresenter/></Border>
              <Border x:Name="mark" Width="3" CornerRadius="2" Background="#F2B84B" HorizontalAlignment="Left" Margin="0,10" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1B2027"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="#222831"/>
                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="9,3"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Background" Value="#183526"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding StatusKey}" Value="disabled"><Setter Property="Background" Value="#262B33"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKey}" Value="locked"><Setter Property="Background" Value="#3A1F22"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKey}" Value="expired"><Setter Property="Background" Value="#3A2E15"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="PillText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#4CC38A"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding StatusKey}" Value="disabled"><Setter Property="Foreground" Value="#8B95A3"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKey}" Value="locked"><Setter Property="Foreground" Value="#E5645A"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusKey}" Value="expired"><Setter Property="Foreground" Value="#F2B84B"/></DataTrigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#2E3540" Margin="1,0"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#232932"/>
      <Setter Property="Foreground" Value="#E4E7EC"/>
      <Setter Property="BorderBrush" Value="#3A4250"/>
      <Setter Property="Padding" Value="10,6"/>
    </Style>

    <!-- Tarjeta de servidor: la barra izquierda hace de LED de rack -->
    <DataTemplate x:Key="Card">
      <Border x:Name="card" Width="282" Margin="0,0,14,14" CornerRadius="10" Background="#1B2027"
              BorderBrush="#262C35" BorderThickness="1" Cursor="Hand" ClipToBounds="True">
        <Grid>
          <Border x:Name="led" Width="4" HorizontalAlignment="Left" Background="#3A4250" CornerRadius="10,0,0,10"/>
          <StackPanel Margin="20,16,16,16">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top" Margin="8,3,0,0">
                <Ellipse x:Name="dot" Width="7" Height="7" Fill="#5D6674"/>
                <TextBlock x:Name="stxt" Text="Sin comprobar" FontSize="11" Foreground="#7D8796" Margin="6,0,0,0"/>
              </StackPanel>
              <TextBlock Text="{Binding Name}" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
              <Border x:Name="proto" CornerRadius="4" Background="#232932" Padding="5,1" Margin="0,0,8,0" VerticalAlignment="Center">
                <TextBlock x:Name="protoTxt" Text="{Binding ProtoLabel}" FontSize="10" FontWeight="SemiBold" Foreground="#7D8796"/>
              </Border>
              <TextBlock Text="{Binding Address}" FontFamily="{StaticResource Mono}" FontSize="12" Foreground="#A3ACB9"
                         TextTrimming="CharacterEllipsis" MaxWidth="200"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE77B;" FontSize="12" Foreground="#7D8796"/>
              <TextBlock Text="{Binding UserDisplay}" FontSize="12" Foreground="#C3CAD4" Margin="7,0,0,0"
                         MaxWidth="150" TextTrimming="CharacterEllipsis"/>
              <Border CornerRadius="5" Background="#232932" Padding="7,2" Margin="10,0,0,0">
                <TextBlock Text="{Binding Group}" FontSize="11" Foreground="#A3ACB9" MaxWidth="80" TextTrimming="CharacterEllipsis"/>
              </Border>
            </StackPanel>
            <TextBlock x:Name="notes" Text="{Binding Notes}" FontSize="12" Foreground="#7D8796" Margin="0,8,0,0"
                       TextTrimming="CharacterEllipsis" Visibility="Collapsed" ToolTip="{Binding Notes}"/>
            <Grid Margin="0,16,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Button Tag="connect" Style="{StaticResource BtnAccent}" Padding="10,7">
                <StackPanel Orientation="Horizontal" IsHitTestVisible="False">
                  <TextBlock x:Name="cicon" Style="{StaticResource Icon}" Text="&#xE8A7;" FontSize="12"/>
                  <TextBlock Text="Conectar" Margin="8,0,0,0"/>
                </StackPanel>
              </Button>
              <Button x:Name="psbtn" Grid.Column="1" Tag="ps" Style="{StaticResource BtnGhost}" Margin="6,0,0,0" ToolTip="Consola PowerShell remota">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE756;" FontSize="13" IsHitTestVisible="False"/>
              </Button>
              <Button Grid.Column="2" Tag="edit" Style="{StaticResource BtnGhost}" Margin="2,0,0,0" ToolTip="Editar">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE70F;" FontSize="13" IsHitTestVisible="False"/>
              </Button>
              <Button Grid.Column="3" Tag="delete" Style="{StaticResource BtnGhost}" Margin="2,0,0,0" ToolTip="Eliminar">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE74D;" FontSize="13" IsHitTestVisible="False"/>
              </Button>
            </Grid>
            <TextBlock Text="{Binding LastDisplay}" FontSize="11" Foreground="#5D6674" Margin="0,10,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Status}" Value="online">
          <Setter TargetName="led" Property="Background" Value="#4CC38A"/>
          <Setter TargetName="dot" Property="Fill" Value="#4CC38A"/>
          <Setter TargetName="stxt" Property="Text" Value="En línea"/>
          <Setter TargetName="stxt" Property="Foreground" Value="#4CC38A"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="offline">
          <Setter TargetName="led" Property="Background" Value="#E5645A"/>
          <Setter TargetName="dot" Property="Fill" Value="#E5645A"/>
          <Setter TargetName="stxt" Property="Text" Value="Sin respuesta"/>
          <Setter TargetName="stxt" Property="Foreground" Value="#E5645A"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="checking">
          <Setter TargetName="led" Property="Background" Value="#F2B84B"/>
          <Setter TargetName="dot" Property="Fill" Value="#F2B84B"/>
          <Setter TargetName="stxt" Property="Text" Value="Comprobando…"/>
          <Setter TargetName="stxt" Property="Foreground" Value="#F2B84B"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding HasNotes}" Value="True">
          <Setter TargetName="notes" Property="Visibility" Value="Visible"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding IsSsh}" Value="True">
          <Setter TargetName="proto" Property="Background" Value="#1D2B3A"/>
          <Setter TargetName="protoTxt" Property="Foreground" Value="#7FB4E8"/>
          <Setter TargetName="cicon" Property="Text" Value="&#xE756;"/>
          <Setter TargetName="psbtn" Property="Visibility" Value="Collapsed"/>
        </DataTrigger>
        <Trigger SourceName="card" Property="IsMouseOver" Value="True">
          <Setter TargetName="card" Property="BorderBrush" Value="#3A4250"/>
          <Setter TargetName="card" Property="Background" Value="#1E242C"/>
        </Trigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <!-- Fila de equipo -->
    <DataTemplate x:Key="PcRow">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="46"/>
          <ColumnDefinition/>
          <ColumnDefinition Width="150"/>
          <ColumnDefinition Width="100"/>
          <ColumnDefinition Width="130"/>
          <ColumnDefinition Width="150"/>
        </Grid.ColumnDefinitions>
        <Border Width="32" Height="32" CornerRadius="8" Background="#232932" HorizontalAlignment="Left">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE7F8;" FontSize="14" Foreground="#A3ACB9" HorizontalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
          <TextBlock Text="{Binding Name}" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock Text="{Binding Subtitle}" FontSize="12" Foreground="#7D8796" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,10,0" ToolTip="{Binding SessionTip}" Background="Transparent">
          <TextBlock x:Name="sicon" Style="{StaticResource Icon}" Text="&#xE77B;" FontSize="11" Foreground="#5D6674" Visibility="Collapsed" Margin="0,0,7,0"/>
          <TextBlock x:Name="sess" Text="{Binding SessionText}" FontSize="12" Foreground="#5D6674" TextTrimming="CharacterEllipsis" MaxWidth="130"/>
        </StackPanel>
        <TextBlock x:Name="last" Grid.Column="3" Text="{Binding LastLogonText}" FontSize="12" Foreground="#A3ACB9" VerticalAlignment="Center"/>
        <StackPanel Grid.Column="4" Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="dot" Width="7" Height="7" Fill="#5D6674"/>
          <TextBlock x:Name="stxt" Text="Sin comprobar" FontSize="12" Foreground="#7D8796" Margin="7,0,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="5" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button Tag="connect" Style="{StaticResource Btn}" Padding="10,6">
            <StackPanel Orientation="Horizontal" IsHitTestVisible="False">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE8A7;" FontSize="11"/>
              <TextBlock Text="Conectar" Margin="7,0,0,0"/>
            </StackPanel>
          </Button>
          <Button Tag="ps" Style="{StaticResource BtnGhost}" Margin="4,0,0,0" ToolTip="Consola PowerShell remota en este equipo">
            <TextBlock Style="{StaticResource Icon}" Text="&#xE756;" FontSize="13" IsHitTestVisible="False"/>
          </Button>
        </StackPanel>
      </Grid>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Status}" Value="online">
          <Setter TargetName="dot" Property="Fill" Value="#4CC38A"/>
          <Setter TargetName="stxt" Property="Text" Value="En línea"/>
          <Setter TargetName="stxt" Property="Foreground" Value="#4CC38A"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="offline">
          <Setter TargetName="dot" Property="Fill" Value="#E5645A"/>
          <Setter TargetName="stxt" Property="Text" Value="Sin respuesta"/>
          <Setter TargetName="stxt" Property="Foreground" Value="#E5645A"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="checking">
          <Setter TargetName="dot" Property="Fill" Value="#F2B84B"/>
          <Setter TargetName="stxt" Property="Text" Value="Comprobando…"/>
          <Setter TargetName="stxt" Property="Foreground" Value="#F2B84B"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Inactive}" Value="True">
          <Setter TargetName="last" Property="Foreground" Value="#F2B84B"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding SessionState}" Value="user">
          <Setter TargetName="sess" Property="Foreground" Value="#E4E7EC"/>
          <Setter TargetName="sicon" Property="Visibility" Value="Visible"/>
          <Setter TargetName="sicon" Property="Foreground" Value="#4CC38A"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding SessionState}" Value="nobody">
          <Setter TargetName="sess" Property="Foreground" Value="#7D8796"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding SessionState}" Value="checking">
          <Setter TargetName="sess" Property="Foreground" Value="#F2B84B"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding SessionState}" Value="error">
          <Setter TargetName="sess" Property="Foreground" Value="#A3ACB9"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <!-- Fila de buffer -->
    <DataTemplate x:Key="BufRow">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="46"/>
          <ColumnDefinition/>
          <ColumnDefinition Width="130"/>
          <ColumnDefinition Width="110"/>
          <ColumnDefinition Width="90"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Width="32" Height="32" CornerRadius="8" Background="#232932" HorizontalAlignment="Left">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE9D2;" FontSize="14" Foreground="#A3ACB9" HorizontalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
          <TextBlock Text="{Binding Name}" FontSize="13" FontWeight="SemiBold"/>
          <TextBlock Text="{Binding Detalle}" FontSize="12" Foreground="#7D8796" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"
                     ToolTip="{Binding Detalle}"/>
        </StackPanel>
        <Border Grid.Column="2" Style="{StaticResource Pill}">
          <TextBlock Style="{StaticResource PillText}" Text="{Binding EstadoText}"/>
        </Border>
        <TextBlock Grid.Column="3" Text="{Binding SpSinceText}" FontSize="12" Foreground="#A3ACB9" VerticalAlignment="Center"/>
        <TextBlock x:Name="up" Grid.Column="4" Text="{Binding UptimeText}" FontSize="12" Foreground="#A3ACB9" VerticalAlignment="Center"
                   ToolTip="Tiempo desde el último reinicio del equipo"/>
        <StackPanel Grid.Column="5" Orientation="Horizontal" VerticalAlignment="Center">
          <Button Tag="sp" Style="{StaticResource Btn}" Padding="10,6" IsEnabled="{Binding CanRestartSp}"
                  ToolTip="{Binding AppTip}">
            <StackPanel Orientation="Horizontal" IsHitTestVisible="False">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE72C;" FontSize="11"/>
              <TextBlock Text="{Binding AppLabel}" Margin="7,0,0,0"/>
            </StackPanel>
          </Button>
          <Button Tag="reboot" Style="{StaticResource Btn}" Padding="10,6" Margin="6,0,0,0" IsEnabled="{Binding CanReboot}"
                  ToolTip="Reinicia el equipo">
            <StackPanel Orientation="Horizontal" IsHitTestVisible="False">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE7E8;" FontSize="11"/>
              <TextBlock Text="Reiniciar" Margin="7,0,0,0"/>
            </StackPanel>
          </Button>
          <Button Tag="rdp" Style="{StaticResource BtnGhost}" Margin="4,0,0,0" ToolTip="Escritorio remoto">
            <TextBlock Style="{StaticResource Icon}" Text="&#xE8A7;" FontSize="13" IsHitTestVisible="False"/>
          </Button>
          <Button Tag="ps" Style="{StaticResource BtnGhost}" Margin="2,0,0,0" ToolTip="Consola PowerShell remota">
            <TextBlock Style="{StaticResource Icon}" Text="&#xE756;" FontSize="13" IsHitTestVisible="False"/>
          </Button>
        </StackPanel>
      </Grid>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding LongUptime}" Value="True">
          <Setter TargetName="up" Property="Foreground" Value="#F2B84B"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <!-- Fila de usuario -->
    <DataTemplate x:Key="UserRow">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="46"/>
          <ColumnDefinition/>
          <ColumnDefinition Width="120"/>
          <ColumnDefinition Width="150"/>
        </Grid.ColumnDefinitions>
        <Border Width="32" Height="32" CornerRadius="16" Background="#232932" HorizontalAlignment="Left">
          <TextBlock Text="{Binding Initials}" FontSize="11" FontWeight="SemiBold" Foreground="#C3CAD4"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,12,0">
          <TextBlock Text="{Binding Name}" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock Text="{Binding Subtitle}" FontSize="12" Foreground="#7D8796" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
        </StackPanel>
        <TextBlock x:Name="last" Grid.Column="2" Text="{Binding LastLogonText}" FontSize="12" Foreground="#A3ACB9" VerticalAlignment="Center"/>
        <Border Grid.Column="3" Style="{StaticResource Pill}">
          <TextBlock Style="{StaticResource PillText}" Text="{Binding StatusText}"/>
        </Border>
      </Grid>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Inactive}" Value="True">
          <Setter TargetName="last" Property="Foreground" Value="#F2B84B"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>
  </Window.Resources>

  <Border x:Name="Root" CornerRadius="12" Background="#14171C" BorderBrush="#2A313B" BorderThickness="1">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="236"/>
        <ColumnDefinition/>
      </Grid.ColumnDefinitions>

      <!-- ============ Barra lateral ============ -->
      <Border Background="#101318" CornerRadius="11,0,0,11" BorderBrush="#20252D" BorderThickness="0,0,1,0">
        <DockPanel Margin="14,18,14,16">
          <StackPanel x:Name="Brand" DockPanel.Dock="Top" Orientation="Horizontal" Margin="6,0,0,22" Background="Transparent">
            <Border Width="34" Height="34" CornerRadius="8" Background="#F2B84B">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE7F4;" Foreground="#1C1608" FontSize="16" HorizontalAlignment="Center"/>
            </Border>
            <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Gestor IT" FontSize="15" FontWeight="SemiBold"/>
              <TextBlock Text="Servidores, equipos y usuarios" FontSize="11" Foreground="#7D8796"/>
            </StackPanel>
          </StackPanel>

          <Button x:Name="BtnIp" DockPanel.Dock="Top" Style="{StaticResource Btn}" Padding="12,9" Margin="0,0,0,20"
                  HorizontalContentAlignment="Left" ToolTip="Ctrl+I">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE721;" FontSize="12"/>
              <TextBlock Text="Identificar IP o equipo" Margin="8,0,0,0"/>
            </StackPanel>
          </Button>

          <Border DockPanel.Dock="Bottom" BorderBrush="#20252D" BorderThickness="0,1,0,0" Padding="0,14,0,0" Margin="0,10,0,0">
            <StackPanel>
              <TextBlock Text="Dominio" FontSize="12" Foreground="#7D8796" Margin="8,0,0,6"/>
              <TextBlock x:Name="TxtConn" Text="Sin conectar" FontSize="12" Foreground="#C3CAD4" Margin="8,0,0,12" TextWrapping="Wrap"/>
              <Button x:Name="BtnConn" Style="{StaticResource Btn}" Padding="12,8">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE8D7;" FontSize="12"/>
                  <TextBlock Text="Cambiar conexión" Margin="8,0,0,0"/>
                </StackPanel>
              </Button>
            </StackPanel>
          </Border>

          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <StackPanel Orientation="Horizontal" Margin="8,0,0,6">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE7F4;" FontSize="12" Foreground="#F2B84B"/>
                <TextBlock Text="Servidores" FontSize="12" FontWeight="SemiBold" Foreground="#A3ACB9" Margin="8,0,0,0"/>
                <TextBlock Text="Ctrl+1" FontSize="11" Foreground="#4A525F" Margin="8,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
              <ListBox x:Name="NavServers" Style="{StaticResource NavList}" ItemContainerStyle="{StaticResource NavItem}"
                       ItemTemplate="{StaticResource NavTemplate}" Margin="0,0,0,18"/>

              <StackPanel Orientation="Horizontal" Margin="8,0,0,6">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE7F8;" FontSize="12" Foreground="#F2B84B"/>
                <TextBlock Text="Equipos" FontSize="12" FontWeight="SemiBold" Foreground="#A3ACB9" Margin="8,0,0,0"/>
                <TextBlock Text="Ctrl+2" FontSize="11" Foreground="#4A525F" Margin="8,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
              <ListBox x:Name="NavPcs" Style="{StaticResource NavList}" ItemContainerStyle="{StaticResource NavItem}"
                       ItemTemplate="{StaticResource NavTemplate}" Margin="0,0,0,18"/>

              <StackPanel Orientation="Horizontal" Margin="8,0,0,6">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE716;" FontSize="12" Foreground="#F2B84B"/>
                <TextBlock Text="Usuarios" FontSize="12" FontWeight="SemiBold" Foreground="#A3ACB9" Margin="8,0,0,0"/>
                <TextBlock Text="Ctrl+3" FontSize="11" Foreground="#4A525F" Margin="8,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
              <ListBox x:Name="NavUsers" Style="{StaticResource NavList}" ItemContainerStyle="{StaticResource NavItem}"
                       ItemTemplate="{StaticResource NavTemplate}" Margin="0,0,0,18"/>

              <StackPanel x:Name="BufNavHeader" Orientation="Horizontal" Margin="8,0,0,6">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE9D2;" FontSize="12" Foreground="#F2B84B"/>
                <TextBlock x:Name="BufNavTitle" Text="Pantallas" FontSize="12" FontWeight="SemiBold" Foreground="#A3ACB9" Margin="8,0,0,0"/>
                <TextBlock Text="Ctrl+4" FontSize="11" Foreground="#4A525F" Margin="8,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
              <ListBox x:Name="NavBuffers" Style="{StaticResource NavList}" ItemContainerStyle="{StaticResource NavItem}"
                       ItemTemplate="{StaticResource NavTemplate}"/>
            </StackPanel>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <!-- ============ Zona principal ============ -->
      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="40"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid x:Name="TitleBar" Background="Transparent">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
            <Button x:Name="BtnMin" Style="{StaticResource WinBtn}"><TextBlock Style="{StaticResource Icon}" Text="&#xE921;" FontSize="10"/></Button>
            <Button x:Name="BtnMax" Style="{StaticResource WinBtn}"><TextBlock Style="{StaticResource Icon}" Text="&#xE922;" FontSize="10"/></Button>
            <Button x:Name="BtnClose" Style="{StaticResource WinClose}"><TextBlock Style="{StaticResource Icon}" Text="&#xE8BB;" FontSize="10"/></Button>
          </StackPanel>
        </Grid>

        <Grid Grid.Row="1" Margin="32,0,32,20">
          <Grid.ColumnDefinitions>
            <ColumnDefinition/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel VerticalAlignment="Bottom">
            <TextBlock x:Name="TxtTitle" FontSize="26" FontWeight="SemiBold"
                       FontFamily="Segoe UI Variable Display, Segoe UI" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="TxtSubtitle" Foreground="#7D8796" Margin="0,4,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom" Margin="16,0,0,0">
            <Grid Width="270">
              <TextBox x:Name="TxtSearch" Style="{StaticResource Input}" Padding="34,8,10,8"/>
              <TextBlock Style="{StaticResource Icon}" Text="&#xE721;" Foreground="#7D8796" Margin="12,0,0,0" IsHitTestVisible="False"/>
              <TextBlock x:Name="SearchHint" Foreground="#5D6674" Margin="35,0,10,0" VerticalAlignment="Center"
                         IsHitTestVisible="False" TextTrimming="CharacterEllipsis"/>
            </Grid>
            <Button x:Name="BtnCheck" Style="{StaticResource Btn}" Margin="10,0,0,0" ToolTip="Comprueba si responde el puerto de conexión: RDP o SSH (F5)">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE9D9;" FontSize="12"/>
                <TextBlock Text="Comprobar" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnReload" Style="{StaticResource Btn}" Margin="8,0,0,0" ToolTip="Volver a leer el dominio">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE72C;" FontSize="12"/>
                <TextBlock Text="Recargar" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnExport" Style="{StaticResource Btn}" Margin="8,0,0,0" ToolTip="Guarda lo que estás viendo en un CSV para Excel">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE896;" FontSize="12"/>
                <TextBlock Text="Exportar" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnRetire" Style="{StaticResource Btn}" Margin="8,0,0,0"
                    ToolTip="Deshabilita los equipos seleccionados y los aparta en la OU &quot;Equipos retirados&quot;. Se pueden reactivar">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE7B8;" FontSize="12"/>
                <TextBlock x:Name="TxtRetire" Text="Retirar" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnRestore" Style="{StaticResource Btn}" Margin="8,0,0,0"
                    ToolTip="Vuelve a habilitar los equipos y los devuelve a su ubicación de antes">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE7A7;" FontSize="12"/>
                <TextBlock x:Name="TxtRestore" Text="Reactivar" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnPurge" Style="{StaticResource Btn}" Margin="8,0,0,0" Foreground="#E5645A"
                    ToolTip="Borra los equipos del dominio. No se puede deshacer">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE74D;" FontSize="12"/>
                <TextBlock x:Name="TxtPurge" Text="Eliminar" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnNewUser" Style="{StaticResource BtnAccent}" Margin="8,0,0,0"
                    ToolTip="Si tienes un usuario seleccionado, el nuevo copia su ubicación y sus grupos">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE8FA;" FontSize="12"/>
                <TextBlock Text="Nuevo usuario" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnAdd" Style="{StaticResource BtnAccent}" Margin="8,0,0,0" ToolTip="Ctrl+N">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE710;" FontSize="12"/>
                <TextBlock Text="Añadir servidor" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
          </StackPanel>
        </Grid>

        <!-- Panel: servidores -->
        <Grid x:Name="PanelServers" Grid.Row="2">
          <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,0,6,0">
            <ItemsControl x:Name="Cards" ItemTemplate="{StaticResource Card}" Margin="32,0,18,16">
              <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
            </ItemsControl>
          </ScrollViewer>
          <StackPanel x:Name="SrvMsg" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,60" MaxWidth="380" Visibility="Collapsed">
            <TextBlock x:Name="SrvMsgTitle" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,6"/>
            <TextBlock x:Name="SrvMsgText" Foreground="#7D8796" TextAlignment="Center" TextWrapping="Wrap"/>
          </StackPanel>
        </Grid>

        <!-- Panel: equipos -->
        <Grid x:Name="PanelPcs" Grid.Row="2" Margin="32,0,26,0" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition/>
          </Grid.RowDefinitions>
          <Grid Margin="15,0,22,8">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="46"/>
              <ColumnDefinition/>
              <ColumnDefinition Width="150"/>
              <ColumnDefinition Width="100"/>
              <ColumnDefinition Width="130"/>
              <ColumnDefinition Width="150"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="1" Style="{StaticResource ColHead}" Text="Equipo"/>
            <TextBlock Grid.Column="2" Style="{StaticResource ColHead}" Text="Conectado ahora"/>
            <TextBlock Grid.Column="3" Style="{StaticResource ColHead}" Text="Último inicio"/>
            <TextBlock Grid.Column="4" Style="{StaticResource ColHead}" Text="Escritorio remoto"/>
          </Grid>
          <ListBox x:Name="PcList" Grid.Row="1" Background="Transparent" BorderThickness="0" SelectionMode="Extended"
                   ItemContainerStyle="{StaticResource RowItem}" ItemTemplate="{StaticResource PcRow}"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                   VirtualizingStackPanel.IsVirtualizing="True" VirtualizingStackPanel.VirtualizationMode="Recycling"/>
          <StackPanel x:Name="PcMsg" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,60" MaxWidth="380" Visibility="Collapsed">
            <TextBlock x:Name="PcMsgTitle" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,6"/>
            <TextBlock x:Name="PcMsgText" Foreground="#7D8796" TextAlignment="Center" TextWrapping="Wrap"/>
          </StackPanel>
        </Grid>

        <!-- Panel: buffers -->
        <Grid x:Name="PanelBuffers" Grid.Row="2" Margin="32,0,26,0" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition/>
          </Grid.RowDefinitions>
          <Grid Margin="15,0,22,8">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="46"/>
              <ColumnDefinition/>
              <ColumnDefinition Width="130"/>
              <ColumnDefinition Width="110"/>
              <ColumnDefinition Width="90"/>
              <ColumnDefinition Width="270"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="1" Style="{StaticResource ColHead}" Text="Pantalla"/>
            <TextBlock Grid.Column="2" Style="{StaticResource ColHead}" Text="Estado"/>
            <TextBlock x:Name="BufColApp" Grid.Column="3" Style="{StaticResource ColHead}" Text="Abierto desde"/>
            <TextBlock Grid.Column="4" Style="{StaticResource ColHead}" Text="Encendido"/>
          </Grid>
          <ListBox x:Name="BufList" Grid.Row="1" Background="Transparent" BorderThickness="0"
                   ItemContainerStyle="{StaticResource RowItem}" ItemTemplate="{StaticResource BufRow}"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
          <StackPanel x:Name="BufMsg" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,60" MaxWidth="380" Visibility="Collapsed">
            <TextBlock x:Name="BufMsgTitle" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,6"/>
            <TextBlock x:Name="BufMsgText" Foreground="#7D8796" TextAlignment="Center" TextWrapping="Wrap"/>
          </StackPanel>
        </Grid>

        <!-- Panel: usuarios -->
        <Grid x:Name="PanelUsers" Grid.Row="2" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition/>
            <ColumnDefinition Width="370"/>
          </Grid.ColumnDefinitions>
          <Grid Margin="32,0,20,0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition/>
            </Grid.RowDefinitions>
            <Grid Margin="15,0,22,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="46"/>
                <ColumnDefinition/>
                <ColumnDefinition Width="120"/>
                <ColumnDefinition Width="150"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="1" Style="{StaticResource ColHead}" Text="Nombre"/>
              <TextBlock Grid.Column="2" Style="{StaticResource ColHead}" Text="Último acceso"/>
              <TextBlock Grid.Column="3" Style="{StaticResource ColHead}" Text="Estado"/>
            </Grid>
            <ListBox x:Name="UserList" Grid.Row="1" Background="Transparent" BorderThickness="0"
                     ItemContainerStyle="{StaticResource RowItem}" ItemTemplate="{StaticResource UserRow}"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     VirtualizingStackPanel.IsVirtualizing="True" VirtualizingStackPanel.VirtualizationMode="Recycling"/>
            <StackPanel x:Name="UsrMsg" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,60" MaxWidth="360" Visibility="Collapsed">
              <TextBlock x:Name="UsrMsgTitle" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,6"/>
              <TextBlock x:Name="UsrMsgText" Foreground="#7D8796" TextAlignment="Center" TextWrapping="Wrap"/>
            </StackPanel>
          </Grid>

          <Border Grid.Column="1" Background="#171B21" BorderBrush="#20252D" BorderThickness="1,0,0,0">
            <Grid>
              <TextBlock x:Name="DetailEmpty" Text="Elige un usuario de la lista para ver sus datos y gestionar su cuenta."
                         Foreground="#7D8796" TextWrapping="Wrap" TextAlignment="Center" Margin="40,0"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <ScrollViewer x:Name="Detail" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
                <StackPanel Margin="28,6,26,28">
                  <DockPanel>
                    <Border Width="52" Height="52" CornerRadius="26" Background="#232932">
                      <TextBlock Text="{Binding Initials}" FontSize="17" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
                      <TextBlock Text="{Binding Name}" FontSize="18" FontWeight="SemiBold" TextWrapping="Wrap"
                                 FontFamily="Segoe UI Variable Display, Segoe UI"/>
                      <TextBlock Text="{Binding Sam}" FontFamily="{StaticResource Mono}" FontSize="12" Foreground="#A3ACB9" Margin="0,3,0,0"/>
                    </StackPanel>
                  </DockPanel>
                  <Border Style="{StaticResource Pill}" Margin="66,10,0,0">
                    <TextBlock Style="{StaticResource PillText}" Text="{Binding StatusText}"/>
                  </Border>

                  <Button x:Name="BtnReset" Style="{StaticResource BtnAccent}" Margin="0,22,0,0" Padding="12,10">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE8D7;" FontSize="12"/>
                      <TextBlock Text="Restablecer contraseña" Margin="8,0,0,0"/>
                    </StackPanel>
                  </Button>
                  <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <Button x:Name="BtnUnlock" Style="{StaticResource Btn}" IsEnabled="{Binding Locked}" Padding="10,9"
                            ToolTip="Solo se activa si la cuenta está bloqueada">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Style="{StaticResource Icon}" Text="&#xE785;" FontSize="12"/>
                        <TextBlock Text="Desbloquear" Margin="8,0,0,0"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="BtnToggle" Grid.Column="2" Style="{StaticResource Btn}" Padding="10,9">
                      <TextBlock Text="{Binding ToggleText}"/>
                    </Button>
                  </Grid>
                  <Button x:Name="BtnCloneUser" Style="{StaticResource Btn}" Margin="0,8,0,0" Padding="10,9"
                          ToolTip="Crea un usuario nuevo en la misma ubicación y con los mismos grupos">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE8C8;" FontSize="12"/>
                      <TextBlock Text="Crear otro usuario como este" Margin="8,0,0,0"/>
                    </StackPanel>
                  </Button>

                  <TextBlock Style="{StaticResource Section}" Text="Datos"/>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel>
                      <TextBlock Style="{StaticResource Key}" Text="Correo"/>
                      <TextBlock Style="{StaticResource Key}" Text="Cargo"/>
                      <TextBlock Style="{StaticResource Key}" Text="Departamento"/>
                      <TextBlock Style="{StaticResource Key}" Text="Teléfono"/>
                      <TextBlock Style="{StaticResource Key}" Text="Descripción"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1">
                      <TextBlock Style="{StaticResource Val}" Text="{Binding MailText}"/>
                      <TextBlock Style="{StaticResource Val}" Text="{Binding TitleText}"/>
                      <TextBlock Style="{StaticResource Val}" Text="{Binding DepartmentText}"/>
                      <TextBlock Style="{StaticResource Val}" Text="{Binding PhoneText}"/>
                      <TextBlock Style="{StaticResource Val}" Text="{Binding DescriptionText}" TextWrapping="Wrap"/>
                    </StackPanel>
                  </Grid>

                  <TextBlock Style="{StaticResource Section}" Text="Cuenta"/>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel>
                      <TextBlock Style="{StaticResource Key}" Text="Último acceso"/>
                      <TextBlock Style="{StaticResource Key}" Text="Contraseña"/>
                      <TextBlock Style="{StaticResource Key}" Text="Caduca"/>
                      <TextBlock Style="{StaticResource Key}" Text="Creada"/>
                      <TextBlock Style="{StaticResource Key}" Text="Conectado en"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1">
                      <TextBlock Style="{StaticResource Val}" Text="{Binding LastLogonFull}"
                                 ToolTip="El dominio actualiza este dato cada 9 a 14 días, así que es aproximado"/>
                      <TextBlock Style="{StaticResource Val}" Text="{Binding PwdLastSetText}"/>
                      <TextBlock Style="{StaticResource Val}" Text="{Binding PwdExpiresText}"/>
                      <TextBlock Style="{StaticResource Val}" Text="{Binding CreatedText}"/>
                      <TextBlock Style="{StaticResource Val}" Text="{Binding SessionText}" TextWrapping="Wrap"
                                 ToolTip="Según la última búsqueda de sesiones en la sección Equipos"/>
                    </StackPanel>
                  </Grid>

                  <TextBlock Style="{StaticResource Section}" Text="{Binding GroupsTitle}"/>
                  <ItemsControl ItemsSource="{Binding Groups}">
                    <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <Border CornerRadius="6" Background="#232932" Padding="8,4" Margin="0,0,6,6">
                          <TextBlock Text="{Binding}" FontSize="12" Foreground="#C3CAD4"/>
                        </Border>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                  <TextBlock Text="{Binding Dn}" FontFamily="{StaticResource Mono}" FontSize="11" Foreground="#5D6674"
                             TextWrapping="Wrap" Margin="0,18,0,0"/>
                </StackPanel>
              </ScrollViewer>
            </Grid>
          </Border>
        </Grid>

        <Border Grid.Row="3" BorderBrush="#20252D" BorderThickness="0,1,0,0" Padding="32,10,40,11">
          <TextBlock x:Name="TxtStatus" FontSize="12" Foreground="#7D8796" TextTrimming="CharacterEllipsis"/>
        </Border>
      </Grid>

      <!-- ============ Editor de servidor ============ -->
      <Grid x:Name="Overlay" Grid.ColumnSpan="2" Visibility="Collapsed">
        <Border x:Name="Backdrop" Background="#B0080A0D" CornerRadius="11"/>
        <Border Width="500" Background="#1B2027" CornerRadius="12" BorderBrush="#2E3540" BorderThickness="1"
                Padding="28,26" HorizontalAlignment="Center" VerticalAlignment="Center">
          <StackPanel>
            <TextBlock x:Name="EdTitle" FontSize="20" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI"/>
            <TextBlock x:Name="EdHint" Text="La contraseña no se guarda aquí: Windows te la pedirá al conectar y puede recordarla."
                       Foreground="#7D8796" FontSize="12" Margin="0,5,0,22" TextWrapping="Wrap"/>
            <TextBlock Style="{StaticResource Label}" Text="Tipo de conexión"/>
            <Border Background="#12151A" BorderBrush="#2E3540" BorderThickness="1" CornerRadius="8" Padding="3" Margin="0,0,0,14" HorizontalAlignment="Left">
              <StackPanel Orientation="Horizontal">
                <RadioButton x:Name="EdRdp" GroupName="proto" IsChecked="True" Cursor="Hand" FocusVisualStyle="{x:Null}">
                  <RadioButton.Template>
                    <ControlTemplate TargetType="RadioButton">
                      <Border x:Name="b" CornerRadius="6" Padding="14,6" Background="Transparent">
                        <TextBlock x:Name="t" Text="Windows (RDP)" Foreground="#A3ACB9"/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                          <Setter TargetName="b" Property="Background" Value="#F2B84B"/>
                          <Setter TargetName="t" Property="Foreground" Value="#1C1608"/>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </RadioButton.Template>
                </RadioButton>
                <RadioButton x:Name="EdSsh" GroupName="proto" Cursor="Hand" FocusVisualStyle="{x:Null}">
                  <RadioButton.Template>
                    <ControlTemplate TargetType="RadioButton">
                      <Border x:Name="b" CornerRadius="6" Padding="14,6" Background="Transparent">
                        <TextBlock x:Name="t" Text="Linux (SSH)" Foreground="#A3ACB9"/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                          <Setter TargetName="b" Property="Background" Value="#F2B84B"/>
                          <Setter TargetName="t" Property="Foreground" Value="#1C1608"/>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </RadioButton.Template>
                </RadioButton>
              </StackPanel>
            </Border>
            <TextBlock Style="{StaticResource Label}" Text="Nombre"/>
            <TextBox x:Name="EdName" Style="{StaticResource Input}" Margin="0,0,0,14"/>
            <Grid Margin="0,0,0,14">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition Width="96"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Style="{StaticResource Label}" Text="Equipo o IP"/>
                <TextBox x:Name="EdHost" Style="{StaticResource Input}" FontFamily="{StaticResource Mono}"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Style="{StaticResource Label}" Text="Puerto"/>
                <TextBox x:Name="EdPort" Style="{StaticResource Input}" FontFamily="{StaticResource Mono}"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,14">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Style="{StaticResource Label}" Text="Usuario (opcional)"/>
                <TextBox x:Name="EdUser" Style="{StaticResource Input}"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Style="{StaticResource Label}" Text="Grupo"/>
                <TextBox x:Name="EdGroup" Style="{StaticResource Input}"/>
              </StackPanel>
            </Grid>
            <TextBlock Style="{StaticResource Label}" Text="Notas"/>
            <TextBox x:Name="EdNotes" Style="{StaticResource Input}" Height="62" AcceptsReturn="True"
                     TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Margin="0,0,0,18"/>
            <StackPanel x:Name="EdRdpOpts">
              <CheckBox x:Name="EdFull" Style="{StaticResource Switch}" Content="Pantalla completa"/>
              <CheckBox x:Name="EdMulti" Style="{StaticResource Switch}" Content="Usar todos los monitores"/>
              <CheckBox x:Name="EdAdmin" Style="{StaticResource Switch}" Content="Sesión de administración (/admin)"/>
            </StackPanel>
            <TextBlock x:Name="EdError" Foreground="#E5645A" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
              <Button x:Name="EdCancel" Style="{StaticResource Btn}" Content="Cancelar"/>
              <Button x:Name="EdSave" Style="{StaticResource BtnAccent}" Content="Guardar servidor" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>

      <!-- ============ Identificar IP ============ -->
      <Grid x:Name="IpOverlay" Grid.ColumnSpan="2" Visibility="Collapsed">
        <Border x:Name="IpBackdrop" Background="#B0080A0D" CornerRadius="11"/>
        <Border Width="600" Background="#1B2027" CornerRadius="12" BorderBrush="#2E3540" BorderThickness="1"
                Padding="28,26" HorizontalAlignment="Center" VerticalAlignment="Center">
          <StackPanel>
            <TextBlock Text="Identificar IP o equipo" FontSize="20" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI"/>
            <TextBlock Text="Escribe una IP o un nombre. Se busca en el DNS, en el propio equipo, en el dominio y en tus servidores."
                       Foreground="#7D8796" FontSize="12" Margin="0,5,0,18" TextWrapping="Wrap"/>
            <Grid Margin="0,0,0,18">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="IpInput" Style="{StaticResource Input}" FontFamily="{StaticResource Mono}" FontSize="14"/>
              <Button x:Name="IpGo" Grid.Column="1" Style="{StaticResource BtnAccent}" Margin="10,0,0,0" Content="Buscar"/>
            </Grid>
            <TextBlock x:Name="IpStatus" Foreground="#7D8796" FontSize="12" TextWrapping="Wrap" Visibility="Collapsed" Margin="0,0,0,12"/>
            <ScrollViewer MaxHeight="360" VerticalScrollBarVisibility="Auto">
              <ItemsControl x:Name="IpResults">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Grid Margin="0,0,0,9">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition/></Grid.ColumnDefinitions>
                      <TextBlock Text="{Binding Key}" FontSize="12" Foreground="#7D8796"/>
                      <TextBlock x:Name="v" Grid.Column="1" Text="{Binding Value}" FontSize="12" Foreground="#E4E7EC" TextWrapping="Wrap"/>
                    </Grid>
                    <DataTemplate.Triggers>
                      <DataTrigger Binding="{Binding Strong}" Value="True">
                        <Setter TargetName="v" Property="FontWeight" Value="SemiBold"/>
                        <Setter TargetName="v" Property="Foreground" Value="#F2B84B"/>
                      </DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </ScrollViewer>
            <WrapPanel Margin="0,10,0,0">
              <Button x:Name="IpNetBox" Style="{StaticResource Btn}" Margin="0,0,8,8" Content="Ver en NetBox"/>
              <Button x:Name="IpRdp" Style="{StaticResource Btn}" Margin="0,0,8,8" Content="Escritorio remoto" Visibility="Collapsed"/>
              <Button x:Name="IpPs" Style="{StaticResource Btn}" Margin="0,0,8,8" Content="PowerShell remoto" Visibility="Collapsed"/>
              <Button x:Name="IpSsh" Style="{StaticResource Btn}" Margin="0,0,8,8" Content="SSH" Visibility="Collapsed"/>
              <Button x:Name="IpWeb" Style="{StaticResource Btn}" Margin="0,0,8,8" Content="Abrir web" Visibility="Collapsed"/>
              <Button x:Name="IpCopy" Style="{StaticResource Btn}" Margin="0,0,8,8" Content="Copiar resultado" Visibility="Collapsed"/>
            </WrapPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
              <Button x:Name="IpClose" Style="{StaticResource Btn}" Content="Cerrar"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>

      <!-- ============ Conexión al dominio ============ -->
      <Grid x:Name="ConnOverlay" Grid.ColumnSpan="2" Visibility="Collapsed">
        <Border Background="#B0080A0D" CornerRadius="11"/>
        <Border Width="460" Background="#1B2027" CornerRadius="12" BorderBrush="#2E3540" BorderThickness="1"
                Padding="28,26" HorizontalAlignment="Center" VerticalAlignment="Center">
          <StackPanel>
            <TextBlock Text="Conectar al dominio" FontSize="20" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI"/>
            <TextBlock Text="Equipos y usuarios se leen del Directorio Activo. Para desbloquear o cambiar contraseñas, la cuenta necesita permisos."
                       Foreground="#7D8796" FontSize="12" Margin="0,5,0,22" TextWrapping="Wrap"/>
            <TextBlock Style="{StaticResource Label}" Text="Dominio o controlador"/>
            <TextBox x:Name="CnServer" Style="{StaticResource Input}" FontFamily="{StaticResource Mono}" Margin="0,0,0,16"/>
            <CheckBox x:Name="CnCurrent" Style="{StaticResource Switch}" Content="Usar mi sesión de Windows" IsChecked="True"/>
            <StackPanel x:Name="CnCreds" IsEnabled="False" Opacity="0.4" Margin="0,4,0,0">
              <TextBlock Style="{StaticResource Label}" Text="Usuario (DOMINIO\usuario)"/>
              <TextBox x:Name="CnUser" Style="{StaticResource Input}" Margin="0,0,0,14"/>
              <TextBlock Style="{StaticResource Label}" Text="Contraseña"/>
              <PasswordBox x:Name="CnPass" Style="{StaticResource PassInput}" Margin="0,0,0,16"/>
              <CheckBox x:Name="CnRemember" Style="{StaticResource Switch}" Content="Recordar la cuenta en este equipo" Margin="0"
                        ToolTip="Se guarda cifrada con tu usuario de Windows: solo tú, en este PC, puedes usarla"/>
            </StackPanel>
            <TextBlock x:Name="CnError" Foreground="#E5645A" TextWrapping="Wrap" Margin="0,14,0,0" Visibility="Collapsed"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
              <Button x:Name="CnCancel" Style="{StaticResource Btn}" Content="Cancelar"/>
              <Button x:Name="CnConnect" Style="{StaticResource BtnAccent}" Content="Conectar" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>

      <!-- ============ Nuevo usuario ============ -->
      <Grid x:Name="NewUserOverlay" Grid.ColumnSpan="2" Visibility="Collapsed">
        <Border x:Name="NuBackdrop" Background="#B0080A0D" CornerRadius="11"/>
        <Border Width="540" Background="#1B2027" CornerRadius="12" BorderBrush="#2E3540" BorderThickness="1"
                Padding="28,26" HorizontalAlignment="Center" VerticalAlignment="Center">
          <StackPanel>
            <TextBlock Text="Nuevo usuario" FontSize="20" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI"/>
            <TextBlock x:Name="NuTemplate" Foreground="#7D8796" FontSize="12" Margin="0,5,0,22" TextWrapping="Wrap"/>
            <Grid Margin="0,0,0,14">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Style="{StaticResource Label}" Text="Nombre"/>
                <TextBox x:Name="NuFirst" Style="{StaticResource Input}"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Style="{StaticResource Label}" Text="Apellidos"/>
                <TextBox x:Name="NuLast" Style="{StaticResource Input}"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,14">
              <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Style="{StaticResource Label}" Text="Usuario de inicio de sesión"/>
                <TextBox x:Name="NuSam" Style="{StaticResource Input}" FontFamily="{StaticResource Mono}"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Style="{StaticResource Label}" Text="Correo (opcional)"/>
                <TextBox x:Name="NuMail" Style="{StaticResource Input}" FontFamily="{StaticResource Mono}"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,14">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Style="{StaticResource Label}" Text="Cargo (opcional)"/>
                <TextBox x:Name="NuTitle" Style="{StaticResource Input}"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Style="{StaticResource Label}" Text="Departamento"/>
                <TextBox x:Name="NuDept" Style="{StaticResource Input}"/>
              </StackPanel>
            </Grid>
            <TextBlock Style="{StaticResource Label}" Text="Contraseña inicial"/>
            <Grid Margin="0,0,0,18">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="NuPass" Style="{StaticResource Input}" FontFamily="{StaticResource Mono}" FontSize="14"/>
              <Button x:Name="NuGen" Grid.Column="1" Style="{StaticResource Btn}" Margin="8,0,0,0" Padding="11,8" ToolTip="Generar otra">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE72C;" FontSize="13"/>
              </Button>
              <Button x:Name="NuCopy" Grid.Column="2" Style="{StaticResource Btn}" Margin="6,0,0,0" Padding="11,8" ToolTip="Copiar">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE8C8;" FontSize="13"/>
              </Button>
            </Grid>
            <CheckBox x:Name="NuMust" Style="{StaticResource Switch}" Content="Pedir que la cambie al iniciar sesión por primera vez" IsChecked="True"/>
            <TextBlock x:Name="NuError" Foreground="#E5645A" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
              <Button x:Name="NuCancel" Style="{StaticResource Btn}" Content="Cancelar"/>
              <Button x:Name="NuSave" Style="{StaticResource BtnAccent}" Content="Crear usuario" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>

      <!-- ============ Restablecer contraseña ============ -->
      <Grid x:Name="ResetOverlay" Grid.ColumnSpan="2" Visibility="Collapsed">
        <Border x:Name="ResetBackdrop" Background="#B0080A0D" CornerRadius="11"/>
        <Border Width="460" Background="#1B2027" CornerRadius="12" BorderBrush="#2E3540" BorderThickness="1"
                Padding="28,26" HorizontalAlignment="Center" VerticalAlignment="Center">
          <StackPanel>
            <TextBlock Text="Restablecer contraseña" FontSize="20" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI"/>
            <TextBlock x:Name="RsWho" Foreground="#7D8796" FontSize="12" Margin="0,5,0,22" TextWrapping="Wrap"/>
            <TextBlock Style="{StaticResource Label}" Text="Nueva contraseña"/>
            <Grid Margin="0,0,0,18">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="RsPass" Style="{StaticResource Input}" FontFamily="{StaticResource Mono}" FontSize="14"/>
              <Button x:Name="RsGen" Grid.Column="1" Style="{StaticResource Btn}" Margin="8,0,0,0" Padding="11,8" ToolTip="Generar otra">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE72C;" FontSize="13"/>
              </Button>
              <Button x:Name="RsCopy" Grid.Column="2" Style="{StaticResource Btn}" Margin="6,0,0,0" Padding="11,8" ToolTip="Copiar">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE8C8;" FontSize="13"/>
              </Button>
            </Grid>
            <CheckBox x:Name="RsMust" Style="{StaticResource Switch}" Content="Pedir que la cambie al iniciar sesión" IsChecked="True"/>
            <CheckBox x:Name="RsUnlock" Style="{StaticResource Switch}" Content="Desbloquear la cuenta si está bloqueada" IsChecked="True"/>
            <TextBlock x:Name="RsError" Foreground="#E5645A" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
              <Button x:Name="RsCancel" Style="{StaticResource Btn}" Content="Cancelar"/>
              <Button x:Name="RsSave" Style="{StaticResource BtnAccent}" Content="Restablecer contraseña" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$IconFile = Join-Path $PSScriptRoot 'GestorIT.ico'
if (Test-Path $IconFile) { try { $Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconFile) } catch { } }
$ElementNames = @(
    'Root','Brand','TitleBar','BtnMin','BtnMax','BtnClose',
    'NavServers','NavPcs','NavUsers','NavBuffers','BufNavHeader','BufNavTitle','BufColApp','PanelBuffers','BufList','BufMsg','BufMsgTitle','BufMsgText','TxtConn','BtnConn',
    'TxtTitle','TxtSubtitle','TxtSearch','SearchHint','BtnCheck','BtnReload','BtnExport','BtnAdd',
    'BtnRetire','BtnRestore','BtnPurge','TxtRetire','TxtRestore','TxtPurge',
    'PanelServers','Cards','SrvMsg','SrvMsgTitle','SrvMsgText',
    'PanelPcs','PcList','PcMsg','PcMsgTitle','PcMsgText',
    'PanelUsers','UserList','UsrMsg','UsrMsgTitle','UsrMsgText','DetailEmpty','Detail','BtnReset','BtnUnlock','BtnToggle',
    'TxtStatus',
    'Overlay','Backdrop','EdTitle','EdName','EdHost','EdPort','EdUser','EdGroup','EdNotes','EdFull','EdMulti','EdAdmin','EdError','EdCancel','EdSave','EdRdp','EdSsh','EdHint','EdRdpOpts',
    'ConnOverlay','CnServer','CnCurrent','CnCreds','CnUser','CnPass','CnRemember','CnError','CnCancel','CnConnect',
    'ResetOverlay','ResetBackdrop','RsWho','RsPass','RsGen','RsCopy','RsMust','RsUnlock','RsError','RsCancel','RsSave',
    'BtnIp','IpOverlay','IpBackdrop','IpInput','IpGo','IpStatus','IpResults','IpNetBox','IpRdp','IpPs','IpSsh','IpWeb','IpCopy','IpClose',
    'BtnNewUser','BtnCloneUser','NewUserOverlay','NuBackdrop','NuTemplate','NuFirst','NuLast','NuSam','NuMail',
    'NuTitle','NuDept','NuPass','NuGen','NuCopy','NuMust','NuError','NuCancel','NuSave'
)
foreach ($n in $ElementNames) { Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script }

# ---------------------------------------------------------------- Estado
$script:Servers    = New-Object 'System.Collections.Generic.List[RdpServer]'
$script:Pcs        = New-Object 'System.Collections.Generic.List[AdComputer]'
$script:Users      = New-Object 'System.Collections.Generic.List[AdUser]'
$script:SrvView    = New-Object 'System.Collections.ObjectModel.ObservableCollection[RdpServer]'
$script:PcView     = New-Object 'System.Collections.ObjectModel.ObservableCollection[AdComputer]'
$script:UserView   = New-Object 'System.Collections.ObjectModel.ObservableCollection[AdUser]'
$script:SrvNav     = New-Object 'System.Collections.ObjectModel.ObservableCollection[NavItem]'
$script:PcNav      = New-Object 'System.Collections.ObjectModel.ObservableCollection[NavItem]'
$script:UserNav    = New-Object 'System.Collections.ObjectModel.ObservableCollection[NavItem]'

$script:Section    = 'servers'
$script:CurrentNav = $null
$script:SrvGroup   = ''
$script:PcFilter   = 'all'
$script:UserFilter = 'all'
$script:NavGuard   = $false
$script:Editing    = $null
$script:ResetUser  = $null
$script:Conn       = $null
$script:Pending    = $null
$script:LoadJob    = $null
$script:DomainName = ''
$script:LoadedAt   = $null
$script:SrvChecked = $null

$Cards.ItemsSource    = $script:SrvView
$PcList.ItemsSource   = $script:PcView
$UserList.ItemsSource = $script:UserView
$NavServers.ItemsSource = $script:SrvNav
$NavPcs.ItemsSource     = $script:PcNav
$NavUsers.ItemsSource   = $script:UserNav

$script:Buffers   = New-Object 'System.Collections.Generic.List[BufferPc]'
$script:BufView   = New-Object 'System.Collections.ObjectModel.ObservableCollection[BufferPc]'
$script:BufNav    = New-Object 'System.Collections.ObjectModel.ObservableCollection[NavItem]'
$script:BufFilter = 'all'
$script:BufChecked = $null
$script:BufServer  = $null     # $true / $false / $null (sin comprobar)
$BufList.ItemsSource    = $script:BufView
$NavBuffers.ItemsSource = $script:BufNav

function New-Nav($section, $key, $name, $title, $count) {
    $n = New-Object NavItem
    $n.Section = $section; $n.Key = $key; $n.Name = $name; $n.Title = $title; $n.Count = $count
    $n
}
foreach ($f in @(
    @('all', 'Todos', 'Todos los equipos'), @('w11', 'Windows 11', 'Windows 11'), @('w10', 'Windows 10', 'Windows 10'),
    @('other', 'Otros sistemas', 'Otros sistemas'), @('inactive', 'Sin iniciar en 90 días', 'Sin iniciar en 90 días'),
    @('session', 'Con alguien conectado', 'Con alguien conectado'),
    @('disabled', 'Deshabilitados', 'Equipos deshabilitados'),
    @('retired', 'Retirados', 'Equipos retirados'),
    @('retired30', 'Retirados hace +30 días', 'Retirados hace más de 30 días'))) {
    $script:PcNav.Add((New-Nav 'pcs' $f[0] $f[1] $f[2] 0))
}
foreach ($f in @(
    @('all', 'Todos', 'Todos los usuarios'), @('active', 'Activos', 'Cuentas activas'), @('locked', 'Bloqueados', 'Cuentas bloqueadas'),
    @('expired', 'Contraseña caducada', 'Contraseña caducada'), @('inactive', 'Sin entrar en 90 días', 'Sin entrar en 90 días'),
    @('online', 'Conectados ahora', 'Conectados ahora'),
    @('disabled', 'Deshabilitados', 'Cuentas deshabilitadas'))) {
    $script:UserNav.Add((New-Nav 'users' $f[0] $f[1] $f[2] 0))
}

# ---------------------------------------------------------------- Servidores: datos
# Servidores con los que arranca la lista la primera vez (config.json > DefaultServers)
$DefaultServers = @(Get-Cfg 'DefaultServers' @())

function Save-Servers {
    $list = foreach ($s in $script:Servers) {
        [pscustomobject]@{
            Id = $s.Id; Name = $s.Name; Host = $s.Host; Port = $s.Port; User = $s.User
            Group = $s.Group; Notes = $s.Notes; FullScreen = $s.FullScreen; MultiMon = $s.MultiMon
            Admin = $s.Admin; LastConnected = $s.LastConnected; Protocol = $s.Protocol
        }
    }
    $json = ConvertTo-Json -InputObject @($list) -Depth 3
    [IO.File]::WriteAllText($DataFile, $json, (New-Object Text.UTF8Encoding $false))
}

function Import-Servers {
    if (-not (Test-Path $DataFile)) {
        foreach ($d in $DefaultServers) {
            $s = New-Object RdpServer
            if ($d.Protocol) { $s.Protocol = [string]$d.Protocol; $s.Port = $s.DefaultPort }
            if ($d.Port) { $s.Port = [int]$d.Port }
            $s.Name = [string]$d.Name; $s.Host = [string]$d.Host
            if ($d.User)  { $s.User = [string]$d.User }
            if ($d.Group) { $s.Group = [string]$d.Group }
            if ($d.Notes) { $s.Notes = [string]$d.Notes }
            $script:Servers.Add($s)
        }
        Save-Servers
        return
    }
    try {
        $raw = [IO.File]::ReadAllText($DataFile)
        if (-not $raw.Trim()) { return }
        foreach ($o in ($raw | ConvertFrom-Json)) {
            $s = New-Object RdpServer
            if ($o.Protocol) { $s.Protocol = [string]$o.Protocol }
            foreach ($p in 'Id','Name','Host','User','Group','Notes','LastConnected') { if ($o.$p) { $s.$p = [string]$o.$p } }
            if ($o.Port) { $s.Port = [int]$o.Port }
            foreach ($p in 'FullScreen','MultiMon','Admin') { if ($null -ne $o.$p) { $s.$p = [bool]$o.$p } }
            $script:Servers.Add($s)
        }
    } catch {
        [Windows.MessageBox]::Show("No se ha podido leer $DataFile.`n`n$($_.Exception.Message)", 'Gestor IT', 'OK', 'Warning') | Out-Null
    }
}

# ---------------------------------------------------------------- Comprobación del puerto RDP (segundo plano)
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 32)
$script:Pool.Open()
# Las búsquedas de sesión (WMI) son lentas: van en su propia cola para no bloquear "Comprobar"
$script:SessPool = [runspacefactory]::CreateRunspacePool(1, 12)
$script:SessPool.Open()
$SessionTimeout = [TimeSpan]::FromSeconds(30)
$script:Jobs = New-Object System.Collections.ArrayList

$CheckScript = {
    param($h, $p)
    $ok = $false
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($h, $p, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(1500)) { $c.EndConnect($iar); $ok = $true }
    } catch { $ok = $false } finally { $c.Close() }
    $ok
}

$PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$PollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$PollTimer.Add_Tick({
    $sessDone = $false
    foreach ($j in @($script:Jobs)) {
        # Una consulta de sesión que no contesta se abandona en vez de quedarse colgada
        if (-not $j.Handle.IsCompleted -and $j.Kind -eq 'session' -and $j.Started -and ((Get-Date) - $j.Started) -gt $SessionTimeout) {
            try { [void]$j.PS.BeginStop($null, $null) } catch { }
            $j.Target.SessionError = 'El equipo no ha contestado en 30 segundos.'
            $j.Target.SessionState = 'error'
            [void]$script:Jobs.Remove($j)
            $sessDone = $true
            continue
        }
        if ($j.Handle.IsCompleted) {
            if ($j.Kind -eq 'session') {
                $r = $null
                try { $r = $j.PS.EndInvoke($j.Handle) | Select-Object -Last 1 } catch { }
                if ($r) {
                    $j.Target.SessionUser  = [string]$r.User
                    $j.Target.SessionError = [string]$r.Error
                    $j.Target.SessionState = [string]$r.State
                } else { $j.Target.SessionState = 'error'; $j.Target.SessionError = 'La consulta no ha devuelto nada.' }
                $sessDone = $true
            } else {
                $ok = $false
                try { $r = $j.PS.EndInvoke($j.Handle); $ok = [bool]($r | Select-Object -Last 1) } catch { }
                $j.Target.Status = if ($ok) { 'online' } else { 'offline' }
            }
            $j.PS.Dispose()
            [void]$script:Jobs.Remove($j)
        }
    }
    if ($sessDone) { Update-UserSessions }
    if ($script:Jobs.Count -eq 0) { $PollTimer.Stop(); $script:SrvChecked = Get-Date }
    Update-StatusBar
})

function Test-Targets($list) {
    foreach ($t in @($list)) {
        if (-not $t.Host) { continue }
        if (@($script:Jobs | Where-Object { $_.Target -eq $t -and $_.Kind -eq 'rdp' }).Count) { continue }
        $t.Status = 'checking'
        $ps = [powershell]::Create()
        $ps.RunspacePool = $script:Pool
        [void]$ps.AddScript($CheckScript).AddArgument($t.Host).AddArgument($t.Port)
        [void]$script:Jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Target = $t; Kind = 'rdp' })
    }
    if ($script:Jobs.Count) { $PollTimer.Start() }
}

# ---------------------------------------------------------------- Quién está conectado en cada PC
# Consulta por WMI (DCOM) quién tiene abierto el escritorio, tanto en consola como por RDP.
# Antes prueba el puerto 135 para no esperar a los equipos apagados.
$SessionScript = {
    param($h, $user, $pass)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($h, 135, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(1200)) { return [pscustomobject]@{ State = 'unreachable'; User = $null; Error = $null } }
        $c.EndConnect($iar)
    } catch { return [pscustomobject]@{ State = 'unreachable'; User = $null; Error = $null } }
    finally { $c.Close() }

    $s = $null
    try {
        $opt = New-CimSessionOption -Protocol Dcom
        if ($user) {
            $cred = New-Object System.Management.Automation.PSCredential($user, (ConvertTo-SecureString $pass -AsPlainText -Force))
            $s = New-CimSession -ComputerName $h -SessionOption $opt -Credential $cred -OperationTimeoutSec 8 -ErrorAction Stop
        } else {
            $s = New-CimSession -ComputerName $h -SessionOption $opt -OperationTimeoutSec 8 -ErrorAction Stop
        }
        $found = New-Object System.Collections.ArrayList
        # Sesiones con escritorio (consola o RDP): dueños de explorer.exe
        $procs = @(Get-CimInstance -CimSession $s -ClassName Win32_Process -Filter "Name='explorer.exe'" -OperationTimeoutSec 8 -ErrorAction Stop)
        foreach ($pr in $procs) {
            try {
                $o = Invoke-CimMethod -InputObject $pr -MethodName GetOwner -OperationTimeoutSec 8 -ErrorAction Stop
                if ($o.User) { [void]$found.Add("$($o.Domain)\$($o.User)") }
            } catch { }
        }
        if ($found.Count -eq 0) {
            $cs = Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystem -Property UserName -OperationTimeoutSec 8 -ErrorAction Stop
            if ($cs.UserName) { [void]$found.Add([string]$cs.UserName) }
        }
        $u = (@($found | Sort-Object -Unique)) -join ', '
        [pscustomobject]@{ State = $(if ($u) { 'user' } else { 'nobody' }); User = $u; Error = $null }
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        [pscustomobject]@{ State = 'error'; User = $null; Error = $e.Message }
    } finally {
        if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue }
    }
}

function Test-Sessions($list) {
    if (-not $script:Conn) { return }
    foreach ($c in @($list)) {
        if (-not $c -or -not $c.Host -or -not $c.Enabled) { continue }
        if (@($script:Jobs | Where-Object { $_.Target -eq $c -and $_.Kind -eq 'session' }).Count) { continue }
        $c.SessionState = 'checking'
        $ps = [powershell]::Create()
        $ps.RunspacePool = $script:SessPool
        [void]$ps.AddScript($SessionScript).AddArgument($c.Host).AddArgument($script:Conn.User).AddArgument($script:Conn.Pass)
        [void]$script:Jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Target = $c; Kind = 'session'; Started = Get-Date })
    }
    if ($script:Jobs.Count) { $PollTimer.Start() }
}

# Cruza las sesiones encontradas con los usuarios del AD
function Update-UserSessions {
    $map = @{}
    foreach ($c in $script:Pcs) {
        if ($c.SessionState -ne 'user') { continue }
        foreach ($x in ($c.SessionUser -split ',\s*')) {
            if (-not $x) { continue }
            $sam = ($x -split '\\')[-1]
            if (-not $map.ContainsKey($sam)) { $map[$sam] = New-Object System.Collections.ArrayList }
            [void]$map[$sam].Add($c.Name)
        }
    }
    foreach ($u in $script:Users) {
        $v = ''
        if ($u.Sam -and $map.ContainsKey($u.Sam)) { $v = (@($map[$u.Sam]) | Sort-Object -Unique) -join ', ' }
        if ([string]$u.SessionOn -ne $v) { $u.SessionOn = $v; $u.NotifyAll() }
    }
    Update-Counts
}

$AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
$AutoTimer.Interval = [TimeSpan]::FromMinutes(2)
$AutoTimer.Add_Tick({ Test-Targets $script:Servers })

# ---------------------------------------------------------------- Escritorio remoto
function Connect-Rdp([string]$Address, [string]$User, [bool]$Full, [bool]$Multi, [bool]$Admin, [string]$Id) {
    $file = Join-Path $TempDir ('{0}.rdp' -f ($Id -replace '[^\w\-]', '_'))
    $lines = @(
        "full address:s:$Address"
        "screen mode id:i:$(if ($Full) { 2 } else { 1 })"
        "use multimon:i:$(if ($Multi) { 1 } else { 0 })"
        'session bpp:i:32'
        'smart sizing:i:1'
        'dynamic resolution:i:1'
        'compression:i:1'
        'keyboardhook:i:2'
        'redirectclipboard:i:1'
        'redirectprinters:i:0'
        'autoreconnection enabled:i:1'
        'authentication level:i:2'
        'prompt for credentials:i:0'
        'negotiate security layer:i:1'
    )
    if (-not $Full) { $lines += 'desktopwidth:i:1600', 'desktopheight:i:900' }
    if ($User) { $lines += "username:s:$User" }
    Set-Content -Path $file -Value $lines -Encoding Unicode
    $argList = @("`"$file`"")
    if ($Admin) { $argList += '/admin' }
    try { Start-Process -FilePath 'mstsc.exe' -ArgumentList $argList; return $true }
    catch { Show-Error "No se ha podido abrir Escritorio remoto.`n`n$($_.Exception.Message)"; return $false }
}

function Connect-Ssh([RdpServer]$s) {
    $ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (-not (Test-Path $ssh)) {
        $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
        if ($cmd) { $ssh = $cmd.Source } else {
            Show-Error "No encuentro el cliente SSH de Windows.`n`nInstálalo en Configuración > Sistema > Características opcionales > Agregar > ""Cliente OpenSSH"", o desde PowerShell como administrador:`nAdd-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
            return $false
        }
    }
    $target = if ($s.User) { "$($s.User)@$($s.Host)" } else { $s.Host }
    $sshArgs = "-p $($s.Port) $target"
    $title = ($s.Name -replace '[";]', '')
    try {
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt) {
            # Windows Terminal: cada servidor en una pestaña con su nombre
            Start-Process -FilePath $wt.Source -ArgumentList "-w 0 new-tab --title ""$title"" ""$ssh"" $sshArgs"
        } else {
            Start-Process -FilePath $ssh -ArgumentList $sshArgs
        }
        return $true
    } catch { Show-Error "No se ha podido abrir SSH.`n`n$($_.Exception.Message)"; return $false }
}

# Abre una consola PowerShell remota (Enter-PSSession) en una pestaña nueva.
# La consola usa la cuenta del dominio recordada en Gestor IT (la descifra ella misma: es tu mismo usuario de Windows).
# Si WinRM no está activo en el equipo, ofrece activarlo por WMI.
$PsRemoteTemplate = @'
$t = '__TARGET__'
$host.UI.RawUI.WindowTitle = 'PowerShell remoto: __LABEL__'
Write-Host "Conectando a $t por PowerShell remoto..." -ForegroundColor Cyan
if ($t -match '^\d{1,3}(\.\d{1,3}){3}$') {
    try { $n = (Resolve-DnsName $t -ErrorAction Stop | Where-Object NameHost | Select-Object -First 1).NameHost; if ($n) { Write-Host "  $t es $n"; $t = $n } } catch { }
}
$cred = $null
$f = '__CREDFILE__'
if (Test-Path $f) {
    try {
        $o = Get-Content $f -Raw | ConvertFrom-Json
        if ($o.User -and $o.Pass) { $cred = New-Object System.Management.Automation.PSCredential($o.User, (ConvertTo-SecureString $o.Pass)); Write-Host "  Cuenta: $($o.User)" }
    } catch { }
}
if (-not $cred) { Write-Host "  Cuenta: tu sesión de Windows" }
$ok = Test-NetConnection $t -Port 5985 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $ok) {
    Write-Host ""
    Write-Host "El PowerShell remoto (WinRM, puerto 5985) no está activo en $t." -ForegroundColor Yellow
    if ((Read-Host "Activarlo ahora? Se hace por WMI y tarda unos segundos (S/N)") -match '^[sS]') {
        try {
            $so = New-CimSessionOption -Protocol Dcom
            if ($cred) { $cs = New-CimSession -ComputerName $t -Credential $cred -SessionOption $so -ErrorAction Stop }
            else { $cs = New-CimSession -ComputerName $t -SessionOption $so -ErrorAction Stop }
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck"'
            [void](Invoke-CimMethod -CimSession $cs -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd })
            Remove-CimSession $cs
            Write-Host "  Activando" -NoNewline
            foreach ($i in 1..20) {
                Start-Sleep 2; Write-Host "." -NoNewline
                if (Test-NetConnection $t -Port 5985 -InformationLevel Quiet -WarningAction SilentlyContinue) { $ok = $true; break }
            }
            Write-Host ""
            if ($ok) { Write-Host "  Activado." -ForegroundColor Green } else { Write-Host "  No responde aún: puede que el firewall del equipo lo bloquee." -ForegroundColor Red }
        } catch { Write-Host "  No se ha podido activar: $($_.Exception.Message)" -ForegroundColor Red }
    }
}
if ($ok) {
    $p = @{ ComputerName = $t; ErrorAction = 'Stop' }
    if ($cred) { $p.Credential = $cred }
    Write-Host "Escribe 'exit' para salir de la sesión remota." -ForegroundColor DarkGray
    Enter-PSSession @p
}
'@

function Connect-PsRemote([string]$target, [string]$label) {
    if (-not $target) { return }
    $q = { param($v) ([string]$v) -replace "'", "''" }
    $code = $PsRemoteTemplate.Replace('__TARGET__', (& $q $target)).Replace('__LABEL__', (& $q $label)).Replace('__CREDFILE__', (& $q (Join-Path $DataDir 'dominio.json')))
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $psArgs = "-NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64"
    $title = ("PS " + $label) -replace '[";]', ''
    try {
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt) { Start-Process -FilePath $wt.Source -ArgumentList "-w 0 new-tab --title ""$title"" powershell.exe $psArgs" }
        else { Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs }
        Set-Status "Abriendo PowerShell remoto en $label."
    } catch { Show-Error "No se ha podido abrir PowerShell.`n`n$($_.Exception.Message)" }
}

function Connect-Server([RdpServer]$s) {
    if ($s.IsSsh) {
        if (Connect-Ssh $s) { $s.LastConnected = (Get-Date).ToString('dd/MM/yyyy HH:mm'); Save-Servers }
        return
    }
    if (Connect-Rdp $s.Address $s.User $s.FullScreen $s.MultiMon $s.Admin $s.Id) {
        $s.LastConnected = (Get-Date).ToString('dd/MM/yyyy HH:mm')
        Save-Servers
    }
}

function Connect-Pc([AdComputer]$c) {
    if (Connect-Rdp $c.Host '' $true $false $false ('pc-' + $c.Name)) {
        Set-Status "Abriendo escritorio remoto de $($c.Name)."
    }
}

# ---------------------------------------------------------------- Dominio: consulta LDAP
$QueryScript = {
    param($Server, $User, $Pass, $What, $Filter)
    function V($p, $n) { if ($p[$n].Count) { $p[$n][0] } else { $null } }
    function ConvertFrom-AdTime($v) {
        if ($null -eq $v) { return $null }
        try {
            $i = [int64]$v
            if ($i -le 0 -or $i -eq [int64]::MaxValue) { return $null }
            return [DateTime]::FromFileTime($i)
        } catch { return $null }
    }
    function Get-Msg($err) {
        $e = $err.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $m = "$($e.Message) [$($e.GetType().Name)$(if ($e.HResult) { ', 0x{0:X8}' -f $e.HResult })]"
        $ii = $err.InvocationInfo
        if ($ii -and $ii.Line) { $m += " en: $($ii.Line.Trim())" }
        $m
    }
    function New-Entry($path, $auth) {
        if ($User) { New-Object System.DirectoryServices.DirectoryEntry($path, $User, $Pass, $auth) }
        else { New-Object System.DirectoryServices.DirectoryEntry($path, $null, $null, $auth) }
    }
    function Find-All($root, [string]$filter, [string[]]$props, [bool]$paged = $true) {
        $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
        $ds.Filter = $filter
        if ($paged) { $ds.PageSize = 500 }
        $ds.PropertiesToLoad.AddRange($props)
        $out = New-Object System.Collections.ArrayList
        $res = $ds.FindAll()
        try { foreach ($r in $res) { [void]$out.Add($r.Properties) } } finally { $res.Dispose() }
        ,$out.ToArray()   # la coma evita que un único resultado se desenrolle
    }
    # Prueba varias formas de búsqueda y devuelve la primera que funciona
    function Find-Robust($root, [string]$filter, [string[]]$props, [string[]]$extra) {
        $plans = @()
        if ($extra) { $plans += ,@(($props + $extra), $true) }
        $plans += ,@($props, $true)
        $plans += ,@($props, $false)
        $errs = @()
        foreach ($pl in $plans) {
            try { return ,(Find-All $root $filter ([string[]]$pl[0]) $pl[1]) }
            catch { $errs += Get-Msg $_ }
        }
        throw ($errs -join ' | ')
    }

    $step = 'iniciar sesión en el dominio'
    try {
        $prefix = if ($Server) { "LDAP://$Server/" } else { 'LDAP://' }

        # Se prueban varios métodos de autenticación, del más seguro al más compatible.
        # Cada uno se da por bueno solo si consigue buscar usuarios de verdad: leer RootDSE
        # no sirve de prueba porque el dominio lo deja leer sin autenticar.
        # Nunca se usa el inicio de sesión simple sin cifrar, que enviaría la contraseña en claro.
        $tries = @('Secure, Sealing, Signing', 'Secure, Signing', 'Secure')
        if ($Server) { $tries += 'Secure, Signing, ServerBind', 'Secure, ServerBind' }
        $dnc = $null; $auth = $null; $root = $null; $errs = @()
        foreach ($t in $tries) {
            try {
                $a = [System.DirectoryServices.AuthenticationTypes]$t
                if (-not $dnc) {
                    $dse = New-Entry ($prefix + 'RootDSE') $a
                    $dnc = [string]$dse.psbase.Properties['defaultNamingContext'].Value
                    if (-not $dnc) { throw 'el controlador no devuelve el nombre del dominio' }
                }
                $r = New-Entry ($prefix + $dnc) $a
                $r.psbase.RefreshCache([string[]]@('distinguishedName'))   # fuerza el inicio de sesión real
                $probe = New-Object System.DirectoryServices.DirectorySearcher($r)
                $probe.Filter = '(&(objectCategory=person)(objectClass=user))'
                [void]$probe.PropertiesToLoad.Add('samaccountname')
                [void]$probe.FindOne()
                $root = $r; $auth = $a
                break
            } catch { $errs += "$t → $(Get-Msg $_)" }
        }
        if (-not $root) { throw ("ningún método de autenticación ha funcionado.`n" + ($errs -join "`n")) }

        $users = @(); $pcs = @()

        if ($What -ne 'computers') {
            $step = 'leer los usuarios'
            $uf = "(&(objectCategory=person)(objectClass=user)$Filter)"
            $uprops = @('samaccountname','displayname','name','mail','department','title','description','telephonenumber',
                        'distinguishedname','useraccountcontrol','lockouttime','lastlogontimestamp','pwdlastset','whencreated','memberof')
            $computed = @('msds-user-account-control-computed','msds-userpasswordexpirytimecomputed')
            # Algunos controladores no devuelven los atributos calculados en búsquedas amplias: se reintenta sin ellos
            $rows = Find-Robust $root $uf ([string[]]$uprops) ([string[]]$computed)

            $ul = New-Object System.Collections.ArrayList
            $rowErr = $null
            foreach ($p in $rows) {
              try {
                $uac  = [int](V $p 'useraccountcontrol')
                $comp = V $p 'msds-user-account-control-computed'
                $lock = V $p 'lockouttime'
                $pls  = V $p 'pwdlastset'
                $disp = V $p 'displayname'
                if (-not $disp) { $disp = V $p 'name' }
                if ($null -ne $comp) { $locked = [bool]([int]$comp -band 0x10) }
                else { $locked = ($null -ne $lock) -and ([int64]$lock -gt 0) }
                [void]$ul.Add(@{
                    Sam             = [string](V $p 'samaccountname')
                    Name            = [string]$disp
                    Mail            = [string](V $p 'mail')
                    Department      = [string](V $p 'department')
                    Title           = [string](V $p 'title')
                    Description     = [string](V $p 'description')
                    Phone           = [string](V $p 'telephonenumber')
                    Dn              = [string](V $p 'distinguishedname')
                    Enabled         = -not ($uac -band 2)
                    Locked          = $locked
                    PwdExpired      = ($null -ne $comp) -and [bool]([int]$comp -band 0x800000)
                    PwdNeverExpires = [bool]($uac -band 0x10000)
                    PwdMustChange   = ($null -ne $pls) -and ([int64]$pls -eq 0)
                    LastLogon       = ConvertFrom-AdTime (V $p 'lastlogontimestamp')
                    PwdLastSet      = ConvertFrom-AdTime $pls
                    PwdExpires      = ConvertFrom-AdTime (V $p 'msds-userpasswordexpirytimecomputed')
                    Created         = V $p 'whencreated'
                    Groups          = [string[]]@($p['memberof'] | ForEach-Object { (($_ -split ',')[0]) -replace '^CN=', '' } | Sort-Object)
                    GroupDns        = [string[]]@($p['memberof'])
                })
              } catch { if (-not $rowErr) { $rowErr = Get-Msg $_ } }
            }
            if ($rowErr -and $ul.Count -eq 0) { throw $rowErr }
            $users = $ul.ToArray()
        }

        if ($What -ne 'users') {
            $step = 'leer los equipos'
            $rows = Find-Robust $root '(objectCategory=computer)' ([string[]]@(
                'name','dnshostname','operatingsystem','operatingsystemversion','description',
                'lastlogontimestamp','useraccountcontrol','distinguishedname','info')) $null
            $cl = New-Object System.Collections.ArrayList
            foreach ($p in $rows) {
                $os = [string](V $p 'operatingsystem')
                if ($os -like '*Server*') { continue }      # los servidores van en su propia sección
                $ver = [string](V $p 'operatingsystemversion')
                $build = 0
                if ($ver -match '\((\d+)\)') { $build = [int]$Matches[1] }
                if ($os -like '*Windows 11*' -or ($os -like '*Windows*' -and $build -ge 22000)) { $fam = 'Windows 11' }
                elseif ($os -like '*Windows 10*') { $fam = 'Windows 10' }
                else { $fam = 'Otros' }
                $nm  = [string](V $p 'name')
                $dns = [string](V $p 'dnshostname')
                [void]$cl.Add(@{
                    Name        = $nm
                    Host        = $(if ($dns) { $dns } else { $nm })
                    Os          = $os
                    Family      = $fam
                    Description = [string](V $p 'description')
                    Dn          = [string](V $p 'distinguishedname')
                    Enabled     = -not ([int](V $p 'useraccountcontrol') -band 2)
                    LastLogon   = ConvertFrom-AdTime (V $p 'lastlogontimestamp')
                    Info        = [string](V $p 'info')
                })
            }
            $pcs = $cl.ToArray()
        }

        [pscustomobject]@{ Error = $null; Dnc = $dnc; Auth = [string]$auth; Users = $users; Computers = $pcs }
    } catch {
        [pscustomobject]@{ Error = "al $step, $(Get-Msg $_)"; Dnc = $null; Auth = $null; Users = @(); Computers = @() }
    }
}

function Set-AdUserData($u, $h) {
    foreach ($k in 'Sam','Name','Mail','Department','Title','Description','Phone','Dn') { $u.$k = [string]$h.$k }
    foreach ($k in 'Enabled','Locked','PwdExpired','PwdNeverExpires','PwdMustChange') { $u.$k = [bool]$h.$k }
    foreach ($k in 'LastLogon','PwdLastSet','PwdExpires','Created') { $u.$k = $h.$k }
    $u.Groups = [string[]]@($h.Groups)
    $u.GroupDns = [string[]]@($h.GroupDns)
}

function ConvertTo-AdComputer($h) {
    $c = New-Object AdComputer
    foreach ($k in 'Name','Host','Os','Family','Description','Dn') { $c.$k = [string]$h.$k }
    $c.Enabled = [bool]$h.Enabled
    $c.LastLogon = $h.LastLogon
    $m = Read-RetireNote ([string]$h.Info)
    if ($c.Dn -match ',OU=Equipos retirados,' -or $m) {
        $c.Retired = $true
        if ($m) {
            $c.Origin = $m.Origen; $c.RetiredBy = $m.Por
            try { $c.RetiredOn = [datetime]::ParseExact($m.Fecha, 'yyyy-MM-dd', $null) } catch { }
        }
    }
    $c
}

# ---------------------------------------------------------------- Equipos: retirar, reactivar y eliminar
# Al retirar se deshabilita el equipo, se mueve a OU=Equipos retirados y se apunta en su atributo
# "info" (Notas) una línea con la fecha, quién lo hizo, de dónde venía y la descripción anterior,
# para poder dejarlo exactamente como estaba al reactivarlo.
$RetireOuName = 'Equipos retirados'
$RetireTag = 'GestorIT-retirado:'

function Read-RetireNote([string]$info) {
    foreach ($line in ($info -split "`r?`n")) {
        if (-not $line.StartsWith($RetireTag)) { continue }
        $h = @{}
        $rest = $line.Substring($RetireTag.Length).Trim()
        # desc va la última y puede contener "|", así que se separa aparte
        $di = $rest.IndexOf('|desc=')
        if ($di -ge 0) { $h.Desc = $rest.Substring($di + 6); $rest = $rest.Substring(0, $di) }
        foreach ($kv in ($rest -split '\|')) { $i = $kv.IndexOf('='); if ($i -gt 0) { $h[$kv.Substring(0, $i)] = $kv.Substring($i + 1) } }
        return $h
    }
    $null
}

function Remove-RetireNote([string]$info) {
    ((($info -split "`r?`n") | Where-Object { -not $_.StartsWith($RetireTag) }) -join "`r`n").Trim()
}

function New-AdEntry([string]$dn) {
    $c = $script:Conn
    $prefix = if ($c.Server) { "LDAP://$($c.Server)/" } else { 'LDAP://' }
    $auth = if ($c.Auth) { [System.DirectoryServices.AuthenticationTypes]$c.Auth } else { [System.DirectoryServices.AuthenticationTypes]'Secure, Sealing, Signing' }
    if ($c.User) { New-Object System.DirectoryServices.DirectoryEntry(($prefix + $dn), $c.User, $c.Pass, $auth) }
    else { New-Object System.DirectoryServices.DirectoryEntry(($prefix + $dn), $null, $null, $auth) }
}

function Get-DomainDn { ($script:DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ',' }

function Get-RetireOu {
    $domDn = Get-DomainDn
    $ouDn = "OU=$RetireOuName,$domDn"
    $ou = New-AdEntry $ouDn
    try { $ou.psbase.RefreshCache(); return $ou } catch { }
    # No existe: se crea en la raíz del dominio
    $root = New-AdEntry $domDn
    $new = $root.psbase.Children.Add("OU=$RetireOuName", 'organizationalUnit')
    $new.psbase.Properties['description'].Value = 'Equipos sin uso retirados desde Gestor IT. Se pueden reactivar o eliminar desde la app.'
    $new.psbase.CommitChanges()
    New-AdEntry $ouDn
}

function Get-ErrMsg($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; $e.Message }

function Get-WhoAmI { if ($script:Conn.User) { $script:Conn.User } else { "$env:USERDOMAIN\$env:USERNAME" } }

# Devuelve los equipos de la lista que responden en la red (todos a la vez, 1,5 s en total)
function Find-OnlinePcs($list) {
    $probes = foreach ($c in $list) {
        foreach ($port in 135, 3389, 445) {
            $t = New-Object Net.Sockets.TcpClient
            try { [pscustomobject]@{ Pc = $c; Tcp = $t; Iar = $t.BeginConnect($c.Host, $port, $null, $null) } } catch { $t.Close() }
        }
    }
    Start-Sleep -Milliseconds 1500
    $on = @{}
    foreach ($pr in $probes) {
        try { if ($pr.Iar.IsCompleted) { $pr.Tcp.EndConnect($pr.Iar); $on[$pr.Pc.Name] = $pr.Pc } } catch { }
        $pr.Tcp.Close()
    }
    @($on.Values)
}

function Get-SelectedPcs { @($PcList.SelectedItems | ForEach-Object { $_ -as [AdComputer] } | Where-Object { $_ }) }

function Update-PcActions {
    $sel = Get-SelectedPcs
    $toRetire  = @($sel | Where-Object { -not $_.Retired })
    $toRestore = @($sel | Where-Object { $_.Retired })
    $retView = $script:PcFilter -in 'retired', 'retired30'
    $BtnRetire.Visibility  = if ($script:Section -eq 'pcs' -and -not $retView) { 'Visible' } else { 'Collapsed' }
    $BtnRestore.Visibility = if ($script:Section -eq 'pcs' -and $retView) { 'Visible' } else { 'Collapsed' }
    $BtnPurge.Visibility   = if ($script:Section -eq 'pcs' -and $retView) { 'Visible' } else { 'Collapsed' }
    $BtnRetire.IsEnabled  = $toRetire.Count -gt 0
    $BtnRestore.IsEnabled = $toRestore.Count -gt 0
    $BtnPurge.IsEnabled   = $toRestore.Count -gt 0
    $TxtRetire.Text  = if ($toRetire.Count -gt 1)  { "Retirar ($($toRetire.Count))" } else { 'Retirar' }
    $TxtRestore.Text = if ($toRestore.Count -gt 1) { "Reactivar ($($toRestore.Count))" } else { 'Reactivar' }
    $TxtPurge.Text   = if ($toRestore.Count -gt 1) { "Eliminar ($($toRestore.Count))" } else { 'Eliminar' }
}

function Format-PcList($list, [int]$max = 12) {
    $names = @($list | ForEach-Object Name | Sort-Object)
    $t = ($names | Select-Object -First $max) -join ', '
    if ($names.Count -gt $max) { $t += " y $($names.Count - $max) más" }
    $t
}

function Invoke-RetirePcs {
    $sel = @(Get-SelectedPcs | Where-Object { -not $_.Retired })
    if (-not $sel.Count) { return }
    Set-Status 'Comprobando que los equipos no estén encendidos…'
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    $on = @(Find-OnlinePcs $sel)
    $Window.Cursor = $null
    $todo = @($sel | Where-Object { $on -notcontains $_ })
    if (-not $todo.Count) {
        Show-Error "No se retira nada: todos los seleccionados responden en la red, así que siguen en uso.`n`n$(Format-PcList $on)"
        return
    }
    $msg = "¿Retirar $(Format-Count $todo.Count 'equipo' 'equipos')?`n`n$(Format-PcList $todo)`n`n" +
           "Se deshabilitan en el dominio y se mueven a la unidad organizativa «$RetireOuName». Nadie podrá iniciar sesión en ellos, pero se pueden reactivar cuando quieras sin perder nada."
    if ($on.Count) { $msg += "`n`nNo se tocan porque están encendidos: $(Format-PcList $on)" }
    if ([Windows.MessageBox]::Show($Window, $msg, 'Retirar equipos', 'YesNo', 'Warning') -ne 'Yes') { return }

    $errs = @(); $done = 0
    try { $ou = Get-RetireOu } catch { Show-Error "No se ha podido crear la unidad organizativa «$RetireOuName».`n`n$(Get-ErrMsg $_)"; return }
    $who = Get-WhoAmI
    foreach ($c in $todo) {
        try {
            $de = New-AdEntry $c.Dn
            $de.psbase.RefreshCache([string[]]@('userAccountControl', 'description', 'info'))
            $origin = Get-ParentDn $c.Dn
            $oldDesc = [string]$de.psbase.Properties['description'].Value
            $oldInfo = [string]$de.psbase.Properties['info'].Value
            $note = "$RetireTag fecha=$(Get-Date -Format 'yyyy-MM-dd')|por=$who|origen=$origin|desc=$oldDesc"
            $de.psbase.Properties['info'].Value = (($note, (Remove-RetireNote $oldInfo)) | Where-Object { $_ }) -join "`r`n"
            $de.psbase.Properties['description'].Value = "Retirado el $(Get-Date -Format 'dd/MM/yyyy') por $who"
            $de.psbase.Properties['userAccountControl'].Value = ([int]$de.psbase.Properties['userAccountControl'].Value) -bor 2
            $de.psbase.CommitChanges()
            $de.psbase.MoveTo($ou)
            $done++
        } catch { $errs += "$($c.Name): $(Get-ErrMsg $_)" }
    }
    Complete-PcAction "$(Format-Count $done 'equipo retirado' 'equipos retirados')." $errs
}

function Invoke-RestorePcs {
    $sel = @(Get-SelectedPcs | Where-Object { $_.Retired })
    if (-not $sel.Count) { return }
    $msg = "¿Reactivar $(Format-Count $sel.Count 'equipo' 'equipos')?`n`n$(Format-PcList $sel)`n`nSe vuelven a habilitar y se devuelven a su unidad organizativa de antes, con su descripción original."
    if ([Windows.MessageBox]::Show($Window, $msg, 'Reactivar equipos', 'YesNo', 'Question') -ne 'Yes') { return }
    $errs = @(); $done = 0
    foreach ($c in $sel) {
        try {
            $de = New-AdEntry $c.Dn
            $de.psbase.RefreshCache([string[]]@('userAccountControl', 'description', 'info'))
            $note = Read-RetireNote ([string]$de.psbase.Properties['info'].Value)
            $de.psbase.Properties['userAccountControl'].Value = ([int]$de.psbase.Properties['userAccountControl'].Value) -band (-bnot 2)
            if ($note) {
                if ($note.Desc) { $de.psbase.Properties['description'].Value = $note.Desc } else { $de.psbase.Properties['description'].Clear() }
            }
            $info = Remove-RetireNote ([string]$de.psbase.Properties['info'].Value)
            if ($info) { $de.psbase.Properties['info'].Value = $info } else { $de.psbase.Properties['info'].Clear() }
            $de.psbase.CommitChanges()
            if ($note -and $note.Origen) {
                try { $dest = New-AdEntry $note.Origen; $dest.psbase.RefreshCache(); $de.psbase.MoveTo($dest) }
                catch { $errs += "$($c.Name): reactivado, pero su ubicación de antes ($($note.Origen)) ya no existe; se queda en «$RetireOuName»" }
            }
            $done++
        } catch { $errs += "$($c.Name): $(Get-ErrMsg $_)" }
    }
    Complete-PcAction "$(Format-Count $done 'equipo reactivado' 'equipos reactivados')." $errs
}

function Invoke-PurgePcs {
    $sel = @(Get-SelectedPcs | Where-Object { $_.Retired })
    if (-not $sel.Count) { return }
    # Avisar de lo que se pierde: claves de BitLocker y contraseñas LAPS guardadas en el propio equipo
    $bl = @(); $laps = @()
    foreach ($c in $sel) {
        try {
            $de = New-AdEntry $c.Dn
            $ds = New-Object System.DirectoryServices.DirectorySearcher($de)
            $ds.SearchScope = 'OneLevel'; $ds.Filter = '(objectClass=msFVE-RecoveryInformation)'
            if ($ds.FindOne()) { $bl += $c.Name }
            $de.psbase.RefreshCache([string[]]@('ms-Mcs-AdmPwd', 'msLAPS-Password', 'msLAPS-EncryptedPassword'))
            if ($de.psbase.Properties['ms-Mcs-AdmPwd'].Count -or $de.psbase.Properties['msLAPS-Password'].Count -or $de.psbase.Properties['msLAPS-EncryptedPassword'].Count) { $laps += $c.Name }
        } catch { }
    }
    $recent = @($sel | Where-Object { -not $_.RetiredLong })
    $msg = "¿ELIMINAR del dominio $(Format-Count $sel.Count 'equipo' 'equipos')?`n`n$(Format-PcList $sel)`n`nEsto NO se puede deshacer. Si alguno vuelve a aparecer, habrá que unirlo de nuevo al dominio."
    if ($bl.Count)     { $msg += "`n`nATENCIÓN: se perderá la clave de recuperación de BitLocker de: $(Format-PcList $bl). Si tienen el disco cifrado y no la tienes guardada en otro sitio, no podrás recuperar sus datos." }
    if ($laps.Count)   { $msg += "`n`nSe perderá la contraseña LAPS del administrador local de: $(Format-PcList $laps)." }
    if ($recent.Count) { $msg += "`n`nOjo: $(Format-PcList $recent) se retiraron hace menos de 30 días." }
    if ([Windows.MessageBox]::Show($Window, $msg, 'Eliminar equipos', 'YesNo', 'Stop') -ne 'Yes') { return }
    $errs = @(); $done = 0
    foreach ($c in $sel) {
        try { $de = New-AdEntry $c.Dn; $de.psbase.DeleteTree(); $done++ }
        catch { $errs += "$($c.Name): $(Get-ErrMsg $_)" }
    }
    Complete-PcAction "$(Format-Count $done 'equipo eliminado' 'equipos eliminados') del dominio." $errs
}

function Complete-PcAction([string]$ok, $errs) {
    Set-Status $ok
    if ($errs.Count) { [Windows.MessageBox]::Show($Window, "$ok`n`nCon problemas:`n" + ($errs -join "`n"), 'Gestor IT', 'OK', 'Warning') | Out-Null }
    if ($script:Conn) { Start-Load $script:Conn }   # vuelve a leer el dominio para ver los cambios
}

function ConvertTo-DomainName([string]$dnc) {
    (($dnc -split ',') | Where-Object { $_ -like 'DC=*' } | ForEach-Object { $_.Substring(3) }) -join '.'
}

# ---------------------------------------------------------------- Dominio: carga en segundo plano
$LoadTimer = New-Object System.Windows.Threading.DispatcherTimer
$LoadTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$LoadTimer.Add_Tick({
    $j = $script:LoadJob
    if (-not $j -or -not $j.Handle.IsCompleted) { return }
    $LoadTimer.Stop()
    $res = $null
    try { $res = $j.PS.EndInvoke($j.Handle) | Select-Object -Last 1 } catch { $res = [pscustomobject]@{ Error = $_.Exception.Message } }
    $j.PS.Dispose()
    $script:LoadJob = $null
    $BtnReload.IsEnabled = $true
    $CnConnect.IsEnabled = $true
    $CnConnect.Content = 'Conectar'

    if (-not $res -or $res.Error) {
        $msg = if ($res) { $res.Error } else { 'sin respuesta del dominio.' }
        $usedSession = -not $script:Pending.User
        if ($usedSession) { $CnCurrent.IsChecked = $false }
        Show-Conn (Get-FriendlyAdError $msg $usedSession)
        Update-View
        Update-StatusBar
        return
    }

    $script:Conn = $script:Pending
    $script:Conn.Auth = $res.Auth
    Save-DomainLogin $script:Conn
    $script:DomainName = ConvertTo-DomainName $res.Dnc
    $script:Users.Clear()
    foreach ($h in $res.Users) { $u = New-Object AdUser; Set-AdUserData $u $h; $script:Users.Add($u) }
    $script:Pcs.Clear()
    foreach ($h in $res.Computers) { $script:Pcs.Add((ConvertTo-AdComputer $h)) }
    $script:LoadedAt = Get-Date

    $who = if ($script:Conn.User) { $script:Conn.User } else { "$env:USERDOMAIN\$env:USERNAME (tu sesión)" }
    $TxtConn.Text = "$($script:DomainName)`n$who"
    $ConnOverlay.Visibility = 'Collapsed'
    $CnPass.Clear()
    Update-Counts
    Update-View
    Update-StatusBar
    Test-Targets ($script:Pcs | Where-Object { $_.Enabled })
    Test-Sessions $script:Pcs
    Sync-Buffers
    if ($script:Section -eq 'buffers') { Update-View; if (-not $script:BufChecked) { Test-Buffers $script:Buffers } }
})

# Traduce los errores habituales del dominio a algo accionable; el detalle técnico va debajo
function Get-FriendlyAdError([string]$msg, [bool]$usedSession) {
    $hint = $null
    if ($msg -match '0x80072020' -and $usedSession) {
        $hint = 'Tu sesión de Windows no tiene acceso al dominio (pasa si entras con una cuenta local o de Microsoft 365). Escribe una cuenta del dominio (DOMINIO\usuario) y activa "Recordar" para no repetirlo.'
    } elseif ($msg -match '0x8007052E') {
        $hint = 'Usuario o contraseña incorrectos.'
    } elseif ($msg -match '0x80070775') {
        $hint = 'La cuenta está bloqueada en el dominio.'
    } elseif ($msg -match '0x8007203A|0x80072030') {
        $hint = 'No se encuentra el servidor del dominio. Prueba con la IP de un controlador de dominio.'
    } elseif ($msg -match '0x80072020') {
        $hint = 'El dominio ha rechazado la lectura con esta cuenta. Comprueba el usuario (DOMINIO\usuario) y que tenga permisos.'
    }
    if ($hint) { return "$hint`n`nDetalle: $msg" }
    return "No se ha podido conectar $msg"
}

function Start-Load($conn) {
    if ($script:LoadJob) { return }
    $script:Pending = $conn
    $ps = [powershell]::Create()
    [void]$ps.AddScript($QueryScript).AddArgument($conn.Server).AddArgument($conn.User).AddArgument($conn.Pass).AddArgument('both').AddArgument('')
    $script:LoadJob = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    $BtnReload.IsEnabled = $false
    $CnConnect.IsEnabled = $false
    $CnConnect.Content = 'Conectando…'
    $CnError.Visibility = 'Collapsed'
    Update-View
    Set-Status 'Leyendo equipos y usuarios del dominio…'
    $LoadTimer.Start()
}

function Update-OneUser([AdUser]$u) {
    $c = $script:Conn
    $esc = ($u.Sam.ToCharArray() | ForEach-Object {
        switch ([string]$_) { '*' { '\2a' } '(' { '\28' } ')' { '\29' } '\' { '\5c' } default { [string]$_ } }
    }) -join ''
    $r = & $QueryScript $c.Server $c.User $c.Pass 'users' "(sAMAccountName=$esc)"
    if ($r.Error -or -not $r.Users.Count) { return }
    Set-AdUserData $u $r.Users[0]
    $u.NotifyAll()
    Update-Counts
    Update-View
    Show-Detail
}

# ---------------------------------------------------------------- Dominio: acciones sobre usuarios
function New-AdContext($Container) {
    $ns = 'System.DirectoryServices.AccountManagement'
    $ct = [System.DirectoryServices.AccountManagement.ContextType]::Domain
    $c = $script:Conn
    $srv = if ($c.Server) { [string]$c.Server } else { $null }
    $cont = if ($Container) { [string]$Container } else { $null }
    if (-not $c.User) {
        if ($cont) { return New-Object "$ns.PrincipalContext"($ct, $srv, $cont) }
        if ($srv)  { return New-Object "$ns.PrincipalContext"($ct, $srv) }
        return New-Object "$ns.PrincipalContext"($ct)
    }
    # Igual que en la lectura: del método más seguro al más compatible
    $last = $null
    $opts = @('Negotiate, Signing, Sealing', 'Negotiate, Signing', 'Negotiate')
    if ($c.Auth -and $c.Auth -notmatch 'Sealing') { $opts = @('Negotiate, Signing', 'Negotiate', 'Negotiate, Signing, Sealing') }
    foreach ($o in $opts) {
        try {
            $opt = [System.DirectoryServices.AccountManagement.ContextOptions]$o
            return New-Object "$ns.PrincipalContext"($ct, $srv, $cont, $opt, $c.User, $c.Pass)
        } catch { $last = $_ }
    }
    throw $last
}

# Devuelve $null si va bien, o el mensaje de error
function Invoke-AdAction([AdUser]$u, [scriptblock]$Action) {
    $ctx = $null
    try {
        $ctx = New-AdContext
        $up = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity(
                $ctx, [System.DirectoryServices.AccountManagement.IdentityType]::SamAccountName, $u.Sam)
        if (-not $up) { throw "No se encuentra $($u.Sam) en el dominio." }
        & $Action $up
        $up.Dispose()
        return $null
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return $e.Message
    } finally {
        if ($ctx) { $ctx.Dispose() }
    }
}

function New-RandomPassword {
    $U = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $L = 'abcdefghijkmnpqrstuvwxyz'; $N = '23456789'
    $b = New-Object byte[] 12
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($b); $rng.Dispose()
    $blocks = for ($k = 0; $k -lt 3; $k++) {
        $o = $k * 4
        '{0}{1}{2}{3}' -f $U[$b[$o] % $U.Length], $L[$b[$o + 1] % $L.Length], $N[$b[$o + 2] % $N.Length], $L[$b[$o + 3] % $L.Length]
    }
    $blocks -join '-'
}

function Show-Reset {
    $u = $Detail.DataContext
    if (-not $u) { return }
    $script:ResetUser = $u
    $RsWho.Text = "Para $($u.Name) ($($u.Sam)). Cópiala antes de cerrar: no se podrá volver a ver."
    $RsPass.Text = New-RandomPassword
    $RsMust.IsChecked = $true
    $RsUnlock.IsChecked = $true
    $RsError.Visibility = 'Collapsed'
    $ResetOverlay.Visibility = 'Visible'
    $Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Input, [Action]{ [void]$RsPass.Focus(); $RsPass.SelectAll() }) | Out-Null
}

function Hide-Reset { $ResetOverlay.Visibility = 'Collapsed'; $script:ResetUser = $null }

function Save-Reset {
    $u = $script:ResetUser
    $newPass = $RsPass.Text
    if (-not $newPass) { $RsError.Text = 'Escribe una contraseña o genera una.'; $RsError.Visibility = 'Visible'; return }
    $must = [bool]$RsMust.IsChecked
    $unl  = [bool]$RsUnlock.IsChecked
    $action = {
        param($up)
        $up.SetPassword($newPass)
        if ($must) { $up.ExpirePasswordNow() }
        if ($unl -and $up.IsAccountLockedOut()) { $up.UnlockAccount() }
    }.GetNewClosure()
    $err = Invoke-AdAction $u $action
    if ($err) { $RsError.Text = "El dominio no ha aceptado el cambio: $err"; $RsError.Visibility = 'Visible'; return }
    try { [Windows.Clipboard]::SetText($newPass) } catch { }
    Hide-Reset
    Update-OneUser $u
    Set-Status "Contraseña de $($u.Name) restablecida y copiada al portapapeles."
}

# ---------------------------------------------------------------- Dominio: nuevo usuario
$script:NewUserTemplate = $null
$script:MailDomain = ''
$script:AutoFill = $false
$script:SamTouched = $false
$script:MailTouched = $false

function Remove-Accents([string]$t) {
    if (-not $t) { return '' }
    ($t.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '').Normalize([Text.NormalizationForm]::FormC)
}

# Inicial del nombre + primer apellido, en minúsculas y sin tildes (Ana García -> agarcia)
function New-SamFromName([string]$first, [string]$last) {
    $f = (Remove-Accents $first.Trim()) -replace '[^A-Za-z]', ''
    # Primer apellido real, saltando partículas (de la Fuente -> fuente)
    $words = @(($last.Trim() -split '\s+') | Where-Object { $_ -and $_ -notin @('de', 'del', 'la', 'las', 'los', 'y', 'da', 'do', 'dos', 'van', 'von') })
    $l = if ($words.Count) { (Remove-Accents $words[0]) -replace '[^A-Za-z]', '' } else { '' }
    if (-not $f) { return '' }
    $sam = ($f.Substring(0, 1) + $l).ToLower()
    if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }
    $sam
}

function Get-ParentDn([string]$dn) { $dn -replace '^(?:\\.|[^,\\])+,', '' }

function Show-NewUser($tpl) {
    if (-not $script:Conn) { Show-Conn 'Conecta primero al dominio.'; return }
    $script:NewUserTemplate = $tpl
    $script:AutoFill = $true
    foreach ($tb in @($NuFirst, $NuLast, $NuSam, $NuMail, $NuTitle)) { $tb.Text = '' }
    $NuDept.Text = if ($tpl) { [string]$tpl.Department } else { '' }
    $script:AutoFill = $false
    $script:SamTouched = $false; $script:MailTouched = $false
    $script:MailDomain = if ($tpl -and $tpl.Mail -match '@(.+)$') { $Matches[1] } else { $script:DomainName }
    if ($tpl) {
        $ou = (Get-ParentDn $tpl.Dn) -replace ',DC=.*$', ''
        $NuTemplate.Text = "Copia de $($tpl.Name): se creará en $ou y en sus $($tpl.GroupCount) grupos."
    } else {
        $NuTemplate.Text = 'Sin plantilla: se creará en la ubicación por defecto del dominio y sin grupos. Para copiar los grupos de alguien, selecciónalo antes en la lista.'
    }
    $NuPass.Text = New-RandomPassword
    $NuMust.IsChecked = $true
    $NuError.Visibility = 'Collapsed'
    $NuSave.IsEnabled = $true
    $NewUserOverlay.Visibility = 'Visible'
    $Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Input, [Action]{ [void]$NuFirst.Focus() }) | Out-Null
}

function Hide-NewUser { $NewUserOverlay.Visibility = 'Collapsed'; $script:NewUserTemplate = $null }

function Update-NewUserAuto {
    if ($script:AutoFill) { return }
    $script:AutoFill = $true
    if (-not $script:SamTouched) { $NuSam.Text = New-SamFromName $NuFirst.Text $NuLast.Text }
    if (-not $script:MailTouched) { $NuMail.Text = if ($NuSam.Text -and $script:MailDomain) { "$($NuSam.Text)@$($script:MailDomain)" } else { '' } }
    $script:AutoFill = $false
}

function Show-NuError([string]$m) { $NuError.Text = $m; $NuError.Visibility = 'Visible' }

function Save-NewUser {
    $first = $NuFirst.Text.Trim(); $last = $NuLast.Text.Trim()
    $sam = $NuSam.Text.Trim().ToLower(); $mail = $NuMail.Text.Trim()
    $title = $NuTitle.Text.Trim(); $dept = $NuDept.Text.Trim()
    $pass = $NuPass.Text; $must = [bool]$NuMust.IsChecked
    if (-not $first) { Show-NuError 'Escribe el nombre.'; return }
    if (-not $sam) { Show-NuError 'Falta el usuario de inicio de sesión.'; return }
    if ($sam -notmatch '^[a-z0-9._-]{1,20}$') { Show-NuError 'El usuario solo puede llevar letras sin tilde, números, punto, guion o guion bajo, y como mucho 20 caracteres.'; return }
    if (@($script:Users | Where-Object { $_.Sam -eq $sam }).Count) { Show-NuError "Ya existe un usuario $sam en el dominio."; return }
    if (-not $pass) { Show-NuError 'Escribe una contraseña o genera una.'; return }

    $tpl = $script:NewUserTemplate
    $ou = if ($tpl) { Get-ParentDn $tpl.Dn } else { $null }
    $display = ("$first $last").Trim()
    $NuSave.IsEnabled = $false
    $ctx = $null; $gctx = $null; $up = $null; $groupErrs = @()
    try {
        $ctx = New-AdContext $ou
        $up = New-Object System.DirectoryServices.AccountManagement.UserPrincipal($ctx)
        $up.SamAccountName = $sam
        $up.UserPrincipalName = "$sam@$($script:DomainName)"
        $up.GivenName = $first
        if ($last) { $up.Surname = $last }
        $up.DisplayName = $display
        $up.Name = $display
        if ($mail) { $up.EmailAddress = $mail }
        $up.SetPassword($pass)
        $up.Enabled = $true
        $up.Save()
        if ($must) { $up.ExpirePasswordNow() }

        if ($title -or $dept) {
            $de = $up.GetUnderlyingObject()
            if ($title) { $de.psbase.Properties['title'].Value = $title }
            if ($dept)  { $de.psbase.Properties['department'].Value = $dept }
            $de.psbase.CommitChanges()
        }

        if ($tpl -and $tpl.GroupDns) {
            $gctx = New-AdContext $null
            $sid = $up.Sid.Value
            foreach ($gdn in $tpl.GroupDns) {
                try {
                    $g = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity(
                            $gctx, [System.DirectoryServices.AccountManagement.IdentityType]::DistinguishedName, $gdn)
                    if ($g) { $g.Members.Add($gctx, [System.DirectoryServices.AccountManagement.IdentityType]::Sid, $sid); $g.Save(); $g.Dispose() }
                } catch {
                    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
                    $groupErrs += "$((($gdn -split ',')[0]) -replace '^CN=', ''): $($e.Message)"
                }
            }
        }
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        $NuSave.IsEnabled = $true
        Show-NuError "El dominio no ha creado el usuario: $($e.Message)"
        return
    } finally {
        if ($up) { $up.Dispose() }
        if ($ctx) { $ctx.Dispose() }
        if ($gctx) { $gctx.Dispose() }
    }

    try { [Windows.Clipboard]::SetText($pass) } catch { }
    Hide-NewUser
    Add-LoadedUser $sam
    Set-Status "Usuario $sam creado. Su contraseña inicial está copiada en el portapapeles."
    if ($groupErrs.Count) {
        [Windows.MessageBox]::Show($Window, "El usuario se ha creado, pero no se ha podido añadir a estos grupos:`n`n" + ($groupErrs -join "`n"), 'Gestor IT', 'OK', 'Warning') | Out-Null
    }
}

# Lee del dominio un usuario recién creado y lo añade a la lista
function Add-LoadedUser([string]$sam) {
    $c = $script:Conn
    $r = & $QueryScript $c.Server $c.User $c.Pass 'users' "(sAMAccountName=$sam)"
    if ($r.Error -or -not $r.Users.Count) { return }
    $u = New-Object AdUser
    Set-AdUserData $u $r.Users[0]
    $script:Users.Add($u)
    Update-Counts
    Select-Nav $script:UserNav[0]
    $UserList.SelectedItem = $u
    $UserList.ScrollIntoView($u)
}

# ---------------------------------------------------------------- Identificar IP o equipo
$script:IpRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[InfoRow]'
$IpResults.ItemsSource = $script:IpRows
$script:IpJob = $null
$script:IpLast = $null

$IpScript = {
    param($query, $user, $pass)
    $r = @{ Query = $query; Ip = ''; Ping = $false; Dns = ''; NetBios = ''; Mac = ''; Ports = @(); Error = ''
            Session = ''; SessionState = ''; Model = ''; Os = ''; WmiError = '' }
    # Nombre -> IP
    if ($query -match '^\d{1,3}(\.\d{1,3}){3}$') { $r.Ip = $query }
    else {
        try { $r.Ip = [string](@(Resolve-DnsName $query -Type A -ErrorAction Stop | Where-Object IPAddress)[0].IPAddress) } catch { }
        if (-not $r.Ip) { $r.Error = "No encuentro ""$query"" en el DNS."; return $r }
    }
    $ip = $r.Ip
    # Puertos (todos a la vez)
    $tipos = [ordered]@{ 22 = 'SSH'; 80 = 'Web'; 443 = 'Web segura'; 135 = 'Windows (RPC)'; 445 = 'Carpetas compartidas'; 3389 = 'Escritorio remoto'
                         9100 = 'Impresora'; 554 = 'Vídeo RTSP'; 8080 = 'Web alternativa'; 8443 = 'Web de gestión'; 5900 = 'VNC'; 102 = 'Siemens S7'; 502 = 'Modbus'; 5985 = 'PowerShell remoto' }
    $probes = foreach ($port in $tipos.Keys) { $t = New-Object Net.Sockets.TcpClient; try { [pscustomobject]@{ P = $port; T = $t; I = $t.BeginConnect($ip, $port, $null, $null) } } catch { $t.Close() } }
    Start-Sleep -Milliseconds 1200
    $open = foreach ($pr in $probes) { try { if ($pr.I.IsCompleted) { $pr.T.EndConnect($pr.I); $pr.P } } catch { } finally { $pr.T.Close() } }
    $r.Ports = @($open | Sort-Object)
    try { $r.Ping = [bool](Test-Connection $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) } catch { }
    try { $r.Dns = [string](@(Resolve-DnsName $ip -ErrorAction Stop | Where-Object NameHost)[0].NameHost) } catch { }
    try {
        $nb = nbtstat -A $ip 2>$null | Select-String '<00>\s+UNIQUE' | Select-Object -First 1
        if ($nb) { $r.NetBios = ($nb.Line.Trim() -split '\s+')[0] }
    } catch { }
    try {
        $n = Get-NetNeighbor -IPAddress $ip -ErrorAction Stop | Where-Object { $_.State -ne 'Unreachable' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } | Select-Object -First 1
        if ($n) { $r.Mac = $n.LinkLayerAddress }
    } catch { }
    # Si es un Windows y deja consultar: modelo, sistema y quién está conectado
    if ($r.Ports -contains 135) {
        $s = $null
        try {
            $opt = New-CimSessionOption -Protocol Dcom
            if ($user) {
                $cred = New-Object Management.Automation.PSCredential($user, (ConvertTo-SecureString $pass -AsPlainText -Force))
                $s = New-CimSession -ComputerName $ip -Credential $cred -SessionOption $opt -OperationTimeoutSec 8 -ErrorAction Stop
            } else { $s = New-CimSession -ComputerName $ip -SessionOption $opt -OperationTimeoutSec 8 -ErrorAction Stop }
            $cs = Get-CimInstance -CimSession $s Win32_ComputerSystem -OperationTimeoutSec 8
            $os = Get-CimInstance -CimSession $s Win32_OperatingSystem -OperationTimeoutSec 8
            $r.Model = (("$($cs.Manufacturer) $($cs.Model)").Trim())
            $r.Os = [string]$os.Caption
            if (-not $r.NetBios) { $r.NetBios = [string]$cs.Name }
            $found = New-Object System.Collections.ArrayList
            foreach ($pr in @(Get-CimInstance -CimSession $s Win32_Process -Filter "Name='explorer.exe'" -OperationTimeoutSec 8)) {
                try { $o = Invoke-CimMethod -InputObject $pr -MethodName GetOwner -OperationTimeoutSec 8; if ($o.User) { [void]$found.Add("$($o.Domain)\$($o.User)") } } catch { }
            }
            if (-not $found.Count -and $cs.UserName) { [void]$found.Add([string]$cs.UserName) }
            $r.Session = (@($found | Sort-Object -Unique)) -join ', '
            $r.SessionState = if ($r.Session) { 'user' } else { 'nobody' }
        } catch {
            $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
            $r.WmiError = $e.Message
        } finally { if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue } }
    }
    $r
}

$IpTimer = New-Object System.Windows.Threading.DispatcherTimer
$IpTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$IpTimer.Add_Tick({
    $j = $script:IpJob
    if (-not $j) { $IpTimer.Stop(); return }
    $late = ((Get-Date) - $j.Started).TotalSeconds -gt 45
    if (-not $j.Handle.IsCompleted -and -not $late) {
        $IpStatus.Text = "Buscando… $([int]((Get-Date) - $j.Started).TotalSeconds) s"
        return
    }
    $IpTimer.Stop()
    $r = $null
    if ($j.Handle.IsCompleted) { try { $r = $j.PS.EndInvoke($j.Handle) | Select-Object -Last 1 } catch { $IpStatus.Text = "Error: $(Get-ErrMsg $_)" } ; $j.PS.Dispose() }
    else { try { [void]$j.PS.BeginStop($null, $null) } catch { }; $IpStatus.Text = 'La búsqueda ha tardado demasiado.' }
    $script:IpJob = $null
    $IpGo.IsEnabled = $true
    if ($r) { Show-IpResult $r }
})

function Add-IpRow([string]$k, [string]$v, [bool]$strong = $false) {
    if (-not $v) { return }
    $row = New-Object InfoRow; $row.Key = $k; $row.Value = $v; $row.Strong = $strong
    $script:IpRows.Add($row)
}

function Show-IpResult($r) {
    $script:IpRows.Clear()
    $script:IpLast = $r
    if ($r.Error) { $IpStatus.Text = $r.Error; return }
    $IpStatus.Visibility = 'Collapsed'
    $ports = @($r.Ports)
    $short = if ($r.Dns) { ($r.Dns -split '\.')[0] } elseif ($r.NetBios) { $r.NetBios } else { '' }

    # Qué es, según lo que ya conoce Gestor IT
    $pc  = @($script:Pcs | Where-Object { ($r.Dns -and $_.Host -ieq $r.Dns) -or ($short -and $_.Name -ieq $short) -or ($r.NetBios -and $_.Name -ieq $r.NetBios) }) | Select-Object -First 1
    $srv = @($script:Servers | Where-Object { $_.Host -eq $r.Ip -or ($r.Dns -and $_.Host -ieq $r.Dns) -or ($short -and $_.Host -ieq $short) }) | Select-Object -First 1
    $buf = @($script:Buffers | Where-Object { $short -and $_.Name -ieq $short }) | Select-Object -First 1

    $que = if ($srv) { "Servidor «$($srv.Name)» de tu lista (grupo $($srv.Group), $($srv.ProtoLabel))" }
           elseif ($buf) { "Pantalla de dashboard $($buf.Name)" }
           elseif ($pc) { "PC del dominio: $($pc.Name)" }
           elseif ($ports -contains 9100) { 'Probablemente una impresora' }
           elseif ($ports -contains 554) { 'Probablemente una cámara IP' }
           elseif ($ports -contains 102 -or $ports -contains 502) { 'Probablemente un PLC o equipo de automatización' }
           elseif ($ports -contains 3389 -or $ports -contains 135) { 'Un equipo Windows que no está en el dominio (o no lo encuentro)' }
           elseif ($ports -contains 22 -and -not ($ports -contains 135)) { 'Probablemente un Linux, un switch u otro equipo de red' }
           elseif ($ports -contains 80 -or $ports -contains 443) { 'Un aparato con página web de gestión' }
           elseif ($r.Ping) { 'Responde al ping pero no tiene ningún puerto habitual abierto' }
           else { 'No responde: apagado, IP libre, o bloquea todo' }

    Add-IpRow 'Qué es' $que $true
    Add-IpRow 'IP' $r.Ip
    Add-IpRow 'Responde' $(if ($r.Ping -or $ports.Count) { 'Sí' } else { 'No' })
    Add-IpRow 'Nombre DNS' $(if ($r.Dns) { $r.Dns } else { 'sin registro' })
    Add-IpRow 'Nombre Windows' $r.NetBios
    Add-IpRow 'Modelo' $r.Model
    Add-IpRow 'Sistema' $(if ($r.Os) { $r.Os } elseif ($pc) { $pc.Os } else { '' })
    Add-IpRow 'MAC' $(if ($r.Mac) { $r.Mac } else { 'no visible desde aquí (otra VLAN)' })
    if ($r.SessionState -eq 'user') { Add-IpRow 'Conectado ahora' $r.Session $true }
    elseif ($r.SessionState -eq 'nobody') { Add-IpRow 'Conectado ahora' 'Nadie' }
    elseif ($r.WmiError) { Add-IpRow 'Conectado ahora' "No se puede consultar: $($r.WmiError)" }
    if ($pc) {
        Add-IpRow 'En el dominio' "$($pc.Name), último inicio $($pc.LastLogonText.ToLower())$(if ($pc.Retired) { ', RETIRADO' } elseif (-not $pc.Enabled) { ', deshabilitado' })"
        if ($pc.Description) { Add-IpRow 'Descripción AD' $pc.Description }
    }
    if ($srv -and $srv.Notes) { Add-IpRow 'Notas' $srv.Notes }
    if ($buf) { Add-IpRow 'Estado pantalla' "$($buf.EstadoText). $($buf.Detalle)" }
    $tipos = @{ 22 = 'SSH'; 80 = 'Web'; 443 = 'Web segura'; 135 = 'Windows (RPC)'; 445 = 'Carpetas compartidas'; 3389 = 'Escritorio remoto'
                9100 = 'Impresora'; 554 = 'Vídeo RTSP'; 8080 = 'Web 8080'; 8443 = 'Web de gestión'; 5900 = 'VNC'; 102 = 'Siemens S7'; 502 = 'Modbus'; 5985 = 'PowerShell remoto' }
    Add-IpRow 'Puertos abiertos' $(if ($ports.Count) { ($ports | ForEach-Object { "$_ ($($tipos[[int]$_]))" }) -join ', ' } else { 'ninguno de los habituales' })

    $IpRdp.Visibility  = if ($ports -contains 3389) { 'Visible' } else { 'Collapsed' }
    $IpPs.Visibility   = if (@($ports | Where-Object { $_ -in 135, 5985, 3389 }).Count) { 'Visible' } else { 'Collapsed' }
    $IpSsh.Visibility  = if ($ports -contains 22) { 'Visible' } else { 'Collapsed' }
    $IpWeb.Visibility  = if (@($ports | Where-Object { $_ -in 80, 443, 8080, 8443 }).Count) { 'Visible' } else { 'Collapsed' }
    $IpCopy.Visibility = 'Visible'
}

function Show-IpSearch([string]$q) {
    $IpOverlay.Visibility = 'Visible'
    if ($q) { $IpInput.Text = $q }
    $Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Input, [Action]{ [void]$IpInput.Focus(); $IpInput.SelectAll() }) | Out-Null
}

function Start-IpSearch {
    $q = $IpInput.Text.Trim()
    if (-not $q -or $script:IpJob) { return }
    $script:IpRows.Clear()
    foreach ($b in $IpRdp, $IpPs, $IpSsh, $IpWeb, $IpCopy) { $b.Visibility = 'Collapsed' }
    $IpStatus.Visibility = 'Visible'; $IpStatus.Text = 'Buscando…'
    $IpGo.IsEnabled = $false
    $u = if ($script:Conn) { $script:Conn.User } else { $null }
    $p = if ($script:Conn) { $script:Conn.Pass } else { $null }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($IpScript).AddArgument($q).AddArgument($u).AddArgument($p)
    $script:IpJob = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
    $IpTimer.Start()
}

function Get-IpTarget { if ($script:IpLast) { if ($script:IpLast.Dns) { $script:IpLast.Dns } else { $script:IpLast.Ip } } }

$BtnIp.Add_Click({ Show-IpSearch $null })
$IpGo.Add_Click({ Start-IpSearch })
$IpClose.Add_Click({ $IpOverlay.Visibility = 'Collapsed' })
$IpBackdrop.Add_MouseLeftButtonDown({ $IpOverlay.Visibility = 'Collapsed' })
$IpNetBox.Add_Click({
    $q = if ($script:IpLast -and $script:IpLast.Ip) { $script:IpLast.Ip } else { $IpInput.Text.Trim() }
    if ($q -and $CfgNetBox) { Start-Process "$CfgNetBox/search/?q=$([uri]::EscapeDataString($q))" }
})
$IpRdp.Add_Click({ $t = Get-IpTarget; if ($t) { [void](Connect-Rdp $t '' $true $false $false ('ip-' + $script:IpLast.Ip)) } })
$IpPs.Add_Click({ $t = Get-IpTarget; if ($t) { Connect-PsRemote $t $t } })
$IpSsh.Add_Click({
    $t = Get-IpTarget; if (-not $t) { return }
    $tmp = New-Object RdpServer; $tmp.Protocol = 'ssh'; $tmp.Host = $t; $tmp.Port = 22; $tmp.Name = $t
    [void](Connect-Ssh $tmp)
})
$IpWeb.Add_Click({
    $r = $script:IpLast; if (-not $r) { return }
    $ports = @($r.Ports)
    $url = if ($ports -contains 443) { "https://$($r.Ip)" } elseif ($ports -contains 8443) { "https://$($r.Ip):8443" } elseif ($ports -contains 80) { "http://$($r.Ip)" } else { "http://$($r.Ip):8080" }
    Start-Process $url
})
$IpCopy.Add_Click({
    $t = ($script:IpRows | ForEach-Object { "{0}: {1}" -f $_.Key, $_.Value }) -join "`r`n"
    try { [Windows.Clipboard]::SetText($t); Set-Status 'Resultado copiado al portapapeles.' } catch { }
})

# ---------------------------------------------------------------- Dominio: conexión
function Show-Conn([string]$err) {
    if ($script:Conn) {
        $CnServer.Text = [string]$script:Conn.Server
        $CnCurrent.IsChecked = -not $script:Conn.User
        $CnUser.Text = [string]$script:Conn.User
        $CnRemember.IsChecked = [bool]$script:Conn.Remember
    }
    if ($err) { $CnError.Text = $err; $CnError.Visibility = 'Visible' } else { $CnError.Visibility = 'Collapsed' }
    $ConnOverlay.Visibility = 'Visible'
}

function Submit-Conn {
    $server = $CnServer.Text.Trim()
    if ($CnCurrent.IsChecked) { Start-Load @{ Server = $server; User = $null; Pass = $null; Remember = $false }; return }
    $user = ($CnUser.Text.Trim() -replace '\s*\\\s*', '\') -replace '\s*@\s*', '@'
    $CnUser.Text = $user
    $pass = $CnPass.Password
    if (-not $user -or -not $pass) {
        $CnError.Text = 'Escribe el usuario y la contraseña, o activa "Usar mi sesión de Windows".'
        $CnError.Visibility = 'Visible'; return
    }
    if (-not $server) {
        $CnError.Text = 'Con otra cuenta hay que indicar el dominio o la IP de un controlador de dominio.'
        $CnError.Visibility = 'Visible'; return
    }
    Start-Load @{ Server = $server; User = $user; Pass = $pass; Remember = [bool]$CnRemember.IsChecked }
}

$CnServer.Text = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN.ToLower() } else { $CfgController }

# Cuenta recordada: la contraseña se cifra con DPAPI (solo este usuario de Windows en este PC puede descifrarla)
$CredFile = Join-Path $DataDir 'dominio.json'

function Save-DomainLogin($conn) {
    try {
        if (-not $conn.Remember) { if (Test-Path $CredFile) { Remove-Item $CredFile -Force }; return }
        $enc = $null
        if ($conn.User) { $enc = ConvertTo-SecureString $conn.Pass -AsPlainText -Force | ConvertFrom-SecureString }
        $json = [pscustomobject]@{ Server = $conn.Server; User = $conn.User; Pass = $enc } | ConvertTo-Json
        [IO.File]::WriteAllText($CredFile, $json, (New-Object Text.UTF8Encoding $false))
    } catch { }
}

function Get-DomainLogin {
    if (-not (Test-Path $CredFile)) { return $null }
    try {
        $o = [IO.File]::ReadAllText($CredFile) | ConvertFrom-Json
        $pass = $null
        if ($o.User -and $o.Pass) {
            $sec = ConvertTo-SecureString $o.Pass
            $pass = (New-Object System.Net.NetworkCredential('', $sec)).Password
        }
        return @{ Server = [string]$o.Server; User = $(if ($o.User) { [string]$o.User } else { $null }); Pass = $pass; Remember = $true }
    } catch { return $null }   # otro usuario u otro PC: no se puede descifrar, se ignora
}

# ---------------------------------------------------------------- Servidores: editor
function Set-EditorProto([string]$proto) {
    $isSsh = $proto -eq 'ssh'
    $EdRdpOpts.Visibility = if ($isSsh) { 'Collapsed' } else { 'Visible' }
    $EdHint.Text = if ($isSsh) {
        'Se abre en Windows Terminal con el cliente SSH de Windows. La contraseña o la clave las pide el propio SSH, aquí no se guardan.'
    } else { 'La contraseña no se guarda aquí: Windows te la pedirá al conectar y puede recordarla.' }
    # Si el puerto era el por defecto del otro tipo, se cambia solo
    $p = $EdPort.Text.Trim()
    if ($isSsh -and ($p -eq '3389' -or -not $p)) { $EdPort.Text = '22' }
    if (-not $isSsh -and ($p -eq '22' -or -not $p)) { $EdPort.Text = '3389' }
}

function Show-Editor([RdpServer]$s) {
    $script:Editing = $s
    if ($s) {
        $EdTitle.Text = 'Editar servidor'
        $EdName.Text = $s.Name; $EdHost.Text = $s.Host; $EdPort.Text = [string]$s.Port
        $EdUser.Text = $s.User; $EdGroup.Text = $s.Group; $EdNotes.Text = $s.Notes
        $EdFull.IsChecked = $s.FullScreen; $EdMulti.IsChecked = $s.MultiMon; $EdAdmin.IsChecked = $s.Admin
        if ($s.IsSsh) { $EdSsh.IsChecked = $true } else { $EdRdp.IsChecked = $true }
        Set-EditorProto $s.Protocol
        $EdSave.Content = 'Guardar cambios'
    } else {
        $EdTitle.Text = 'Añadir servidor'
        $EdName.Text = ''; $EdHost.Text = ''; $EdPort.Text = '3389'; $EdUser.Text = ''; $EdNotes.Text = ''
        $EdGroup.Text = if ($script:Section -eq 'servers' -and $script:SrvGroup) { $script:SrvGroup } else { 'General' }
        $EdFull.IsChecked = $true; $EdMulti.IsChecked = $false; $EdAdmin.IsChecked = $false
        $EdRdp.IsChecked = $true
        Set-EditorProto 'rdp'
        $EdSave.Content = 'Añadir servidor'
    }
    $EdError.Visibility = 'Collapsed'
    $Overlay.Visibility = 'Visible'
    $Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Input, [Action]{ [void]$EdName.Focus() }) | Out-Null
}

function Hide-Editor { $Overlay.Visibility = 'Collapsed'; $script:Editing = $null }

function Save-Editor {
    $h = $EdHost.Text.Trim()
    $portTxt = $EdPort.Text.Trim()
    if ($h -match '^([^:\s]+):(\d+)$') { $h = $Matches[1]; $portTxt = $Matches[2] }
    if (-not $h) { $EdError.Text = 'Escribe el nombre del equipo o su IP.'; $EdError.Visibility = 'Visible'; return }
    $port = 0
    if (-not [int]::TryParse($portTxt, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        $EdError.Text = 'El puerto tiene que ser un número entre 1 y 65535. Por defecto: 3389 para RDP y 22 para SSH.'
        $EdError.Visibility = 'Visible'; return
    }
    $name = $EdName.Text.Trim(); if (-not $name) { $name = $h }
    $grp  = $EdGroup.Text.Trim(); if (-not $grp) { $grp = 'General' }
    $s = $script:Editing
    $isNew = -not $s
    if ($isNew) { $s = New-Object RdpServer }
    $s.Protocol = if ($EdSsh.IsChecked) { 'ssh' } else { 'rdp' }
    $s.Name = $name; $s.Host = $h; $s.Port = $port
    $s.User = $EdUser.Text.Trim(); $s.Group = $grp; $s.Notes = $EdNotes.Text.Trim()
    $s.FullScreen = [bool]$EdFull.IsChecked; $s.MultiMon = [bool]$EdMulti.IsChecked; $s.Admin = [bool]$EdAdmin.IsChecked
    if ($isNew) { $script:Servers.Add($s) }
    Save-Servers
    Hide-Editor
    Update-ServerNav
    Update-View
    Test-Targets @($s)
}

function Remove-Server([RdpServer]$s) {
    $r = [Windows.MessageBox]::Show($Window, "¿Eliminar «$($s.Name)» de la lista?`n`nNo afecta al servidor, solo a esta aplicación.", 'Eliminar servidor', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    [void]$script:Servers.Remove($s)
    Save-Servers
    Update-ServerNav
    Update-View
}

# ---------------------------------------------------------------- Vistas
function Show-Error([string]$msg) { [Windows.MessageBox]::Show($Window, $msg, 'Gestor IT', 'OK', 'Error') | Out-Null }
function Set-Status([string]$msg) { $TxtStatus.Text = $msg }

function Set-Msg($panel, $titleEl, $textEl, [string]$title, [string]$text) {
    if ($title) { $panel.Visibility = 'Visible'; $titleEl.Text = $title; $textEl.Text = $text }
    else { $panel.Visibility = 'Collapsed' }
}

function Get-DomainMsg([string]$what) {
    if ($script:LoadJob) { return @('Leyendo el dominio…', 'Con unos cientos de objetos tarda pocos segundos.') }
    if (-not $script:Conn) { return @('Sin conexión al dominio', "Pulsa ""Cambiar conexión"" abajo a la izquierda para ver $what.") }
    return $null
}

function Test-PcFilter([AdComputer]$c, [string]$key) {
    switch ($key) {
        'w11'      { return $c.Family -eq 'Windows 11' -and -not $c.Retired }
        'w10'      { return $c.Family -eq 'Windows 10' -and -not $c.Retired }
        'other'    { return $c.Family -eq 'Otros' -and -not $c.Retired }
        'inactive'  { return $c.Inactive }
        'session'   { return $c.SessionState -eq 'user' }
        'disabled'  { return -not $c.Enabled -and -not $c.Retired }
        'retired'   { return $c.Retired }
        'retired30' { return $c.RetiredLong }
        default     { return -not $c.Retired }
    }
}

function Test-UserFilter([AdUser]$u, [string]$key) {
    switch ($key) {
        'active'   { return $u.StatusKey -eq 'active' }
        'locked'   { return $u.Locked }
        'expired'  { return $u.Enabled -and $u.PwdExpired }
        'inactive' { return $u.Inactive }
        'online'   { return [bool]$u.SessionOn }
        'disabled' { return -not $u.Enabled }
        default    { return $true }
    }
}

function Test-Search([string]$q, [string[]]$fields) {
    if (-not $q) { return $true }
    return (($fields -join ' ').IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Format-Count([int]$n, [string]$one, [string]$many) { if ($n -eq 1) { "1 $one" } else { "$n $many" } }

function Update-ServerNav {
    $script:NavGuard = $true
    $cur = $script:SrvGroup
    $script:SrvNav.Clear()
    $script:SrvNav.Add((New-Nav 'servers' '' 'Todos' 'Todos los servidores' $script:Servers.Count))
    $script:Servers | Group-Object -Property Group | Sort-Object Name | ForEach-Object {
        $script:SrvNav.Add((New-Nav 'servers' $_.Name $_.Name $_.Name $_.Count))
    }
    if ($script:Section -eq 'servers') {
        $t = $script:SrvNav | Where-Object { $_.Key -eq $cur } | Select-Object -First 1
        if (-not $t) { $t = $script:SrvNav[0]; $script:SrvGroup = '' }
        $NavServers.SelectedItem = $t
        $script:CurrentNav = $t
    }
    $script:NavGuard = $false
}

function Update-Counts {
    foreach ($n in $script:BufNav) {
        $c = 0; foreach ($x in $script:Buffers) { if ($n.Key -eq 'all' -or $x.IsProblem) { $c++ } }; $n.Count = $c
    }
    foreach ($n in $script:PcNav) {
        $c = 0; foreach ($x in $script:Pcs) { if (Test-PcFilter $x $n.Key) { $c++ } }; $n.Count = $c
    }
    foreach ($n in $script:UserNav) {
        $c = 0; foreach ($x in $script:Users) { if (Test-UserFilter $x $n.Key) { $c++ } }; $n.Count = $c
    }
}

function Update-ServersView {
    $q = $TxtSearch.Text.Trim()
    $script:SrvView.Clear()
    foreach ($s in ($script:Servers | Sort-Object Name)) {
        if ($script:SrvGroup -and $s.Group -ne $script:SrvGroup) { continue }
        if (-not (Test-Search $q @($s.Name, $s.Host, $s.User, $s.Notes))) { continue }
        $script:SrvView.Add($s)
    }
    $n = $script:SrvView.Count
    $TxtSubtitle.Text = (Format-Count $n 'servidor' 'servidores') + '. Doble clic en una tarjeta para conectar.'
    if ($n -gt 0) { Set-Msg $SrvMsg $SrvMsgTitle $SrvMsgText $null $null }
    elseif ($script:Servers.Count -eq 0) { Set-Msg $SrvMsg $SrvMsgTitle $SrvMsgText 'Añade tu primer servidor' 'Pulsa "Añadir servidor" o Ctrl+N. Solo necesitas el nombre del equipo o su IP.' }
    else { Set-Msg $SrvMsg $SrvMsgTitle $SrvMsgText 'Ningún servidor coincide' 'Prueba con otra búsqueda o elige "Todos".' }
}

function Update-PcView {
    $q = $TxtSearch.Text.Trim()
    $sel = $PcList.SelectedItem
    $script:PcView.Clear()
    foreach ($c in ($script:Pcs | Sort-Object Name)) {
        if (-not (Test-PcFilter $c $script:PcFilter)) { continue }
        if (-not (Test-Search $q @($c.Name, $c.Host, $c.Os, $c.Description, $c.SessionUser))) { continue }
        $script:PcView.Add($c)
    }
    if ($sel -and $script:PcView.Contains($sel)) { $PcList.SelectedItem = $sel }
    $n = $script:PcView.Count
    $TxtSubtitle.Text = (Format-Count $n 'equipo' 'equipos')
    if ($script:DomainName) { $TxtSubtitle.Text += " en $($script:DomainName). Doble clic para conectar." }
    $m = Get-DomainMsg 'los equipos'
    if ($m) { Set-Msg $PcMsg $PcMsgTitle $PcMsgText $m[0] $m[1] }
    elseif ($n -eq 0) { Set-Msg $PcMsg $PcMsgTitle $PcMsgText 'Ningún equipo en esta vista' 'Prueba con otra búsqueda o elige "Todos".' }
    else { Set-Msg $PcMsg $PcMsgTitle $PcMsgText $null $null }
}

function Update-UsersView {
    $q = $TxtSearch.Text.Trim()
    $sel = $UserList.SelectedItem
    $script:UserView.Clear()
    foreach ($u in ($script:Users | Sort-Object Name)) {
        if (-not (Test-UserFilter $u $script:UserFilter)) { continue }
        if (-not (Test-Search $q @($u.Name, $u.Sam, $u.Mail, $u.Department, $u.Title, $u.Description))) { continue }
        $script:UserView.Add($u)
    }
    if ($sel -and $script:UserView.Contains($sel)) { $UserList.SelectedItem = $sel }
    $n = $script:UserView.Count
    $TxtSubtitle.Text = (Format-Count $n 'usuario' 'usuarios')
    if ($script:DomainName) { $TxtSubtitle.Text += " en $($script:DomainName)" }
    $m = Get-DomainMsg 'los usuarios'
    if ($m) { Set-Msg $UsrMsg $UsrMsgTitle $UsrMsgText $m[0] $m[1] }
    elseif ($n -eq 0 -and $q) { Set-Msg $UsrMsg $UsrMsgTitle $UsrMsgText 'Ningún usuario coincide' 'Prueba con otra búsqueda o elige "Todos".' }
    elseif ($n -eq 0) { Set-Msg $UsrMsg $UsrMsgTitle $UsrMsgText 'No hay usuarios en esta vista' 'Buena señal si estás mirando bloqueados o contraseñas caducadas.' }
    else { Set-Msg $UsrMsg $UsrMsgTitle $UsrMsgText $null $null }
    Show-Detail
}

# ---------------------------------------------------------------- Pantallas de dashboard (kioscos)
$BufServerHost = $KioskServer        # servidor que sirve el dashboard (vacío = no se comprueba)
[BufferPc]::AppName = $KioskApp
$BufNavTitle.Text = $KioskTitle
$BufColApp.Text = "$KioskApp desde"
if (-not $KioskOn) { $BufNavHeader.Visibility = 'Collapsed'; $NavBuffers.Visibility = 'Collapsed' }
$IpNetBox.Visibility = if ($CfgNetBox) { 'Visible' } else { 'Collapsed' }
$BufTimeout    = [TimeSpan]::FromSeconds(25)
$script:BufPool = [runspacefactory]::CreateRunspacePool(1, 16)
$script:BufPool.Open()
$script:BufJobs = New-Object System.Collections.ArrayList

$BufCheckScript = {
    param($pcHost, $user, $pass, $program, $app)
    $r = @{ Estado = ''; User = ''; Det = ''; SpSince = $null; Boot = $null; SpPath = ''; SpArgs = ''; SpDir = ''; SpUser = '' }
    # Encendido si contesta por WMI (135), escritorio remoto (3389) o archivos compartidos (445)
    $vivo = $false; $rpc = $false
    foreach ($port in 135, 3389, 445) {
        $c = New-Object Net.Sockets.TcpClient
        try { $i = $c.BeginConnect($pcHost, $port, $null, $null); if ($i.AsyncWaitHandle.WaitOne(2500)) { $c.EndConnect($i); $vivo = $true; $rpc = ($port -eq 135) } } catch { } finally { $c.Close() }
        if ($vivo) { break }
    }
    if (-not $vivo) { $r.Estado = 'off'; $r.Det = 'No responde en la red: apagado, sin cable o sin red'; return $r }
    if (-not $rpc) {
        $r.Estado = 'noaccess'
        $r.Det = "Encendido (responde por escritorio remoto), pero su firewall bloquea la consulta WMI (puerto 135): no se puede ver si $app está abierto"
        return $r
    }
    $s = $null
    try {
        $opt = New-CimSessionOption -Protocol Dcom
        if ($user) {
            $cred = New-Object Management.Automation.PSCredential($user, (ConvertTo-SecureString $pass -AsPlainText -Force))
            $s = New-CimSession -ComputerName $pcHost -Credential $cred -SessionOption $opt -OperationTimeoutSec 10 -ErrorAction Stop
        } else { $s = New-CimSession -ComputerName $pcHost -SessionOption $opt -OperationTimeoutSec 10 -ErrorAction Stop }
        $os = Get-CimInstance -CimSession $s Win32_OperatingSystem -OperationTimeoutSec 10
        $r.Boot = $os.LastBootUpTime
        $procs = @(Get-CimInstance -CimSession $s Win32_Process -OperationTimeoutSec 10)
        $exp = @($procs | Where-Object Name -eq 'explorer.exe')
        if (-not $exp) { $r.Estado = 'nosession'; $r.Det = 'Encendido pero nadie ha iniciado sesión: la pantalla está en el inicio de Windows'; return $r }
        $own = Invoke-CimMethod -InputObject $exp[0] -MethodName GetOwner -OperationTimeoutSec 10 -ErrorAction SilentlyContinue
        if ($own.User) { $r.User = [string]$own.User; $r.SpUser = "$($own.Domain)\$($own.User)" }
        $mine = @($procs | Where-Object { $_.SessionId -eq $exp[0].SessionId })
        $sp = @($mine | Where-Object Name -eq $program)
        if ($sp) {
            $r.SpSince = $sp[0].CreationDate
            $r.SpPath = [string]$sp[0].ExecutablePath
            $r.SpDir = if ($r.SpPath) { Split-Path $r.SpPath } else { '' }
            $cl = [string]$sp[0].CommandLine
            $r.SpArgs = if ($cl -match '^\s*"[^"]*"\s*(.*)$') { $Matches[1] } elseif ($cl -match '^\s*\S+\s*(.*)$') { $Matches[1] } else { '' }
        }
        if (-not $sp) { $r.Estado = 'nosp'; $r.Det = "Sesión abierta pero $app está cerrado" }
        elseif (@($mine | Where-Object Name -eq 'LogonUI.exe')) { $r.Estado = 'locked'; $r.Det = "$app abierto, pero la pantalla está bloqueada: no se ve" }
        else { $r.Estado = 'ok'; $r.Det = "$app en marcha con el usuario $($r.User)" }
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        $r.Estado = 'noaccess'; $r.Det = "Responde, pero no deja consultarlo: $($e.Message)"
    } finally { if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue } }
    $r
}

# Cierra la app del dashboard y la vuelve a abrir en la sesión del usuario de la pantalla (con una tarea programada interactiva)
$BufRestartSpScript = {
    param($pcHost, $user, $pass, $spPath, $spArgs, $spDir, $spUser, $program, $app)
    $s = $null
    try {
        $opt = New-CimSessionOption -Protocol Dcom
        if ($user) {
            $cred = New-Object Management.Automation.PSCredential($user, (ConvertTo-SecureString $pass -AsPlainText -Force))
            $s = New-CimSession -ComputerName $pcHost -Credential $cred -SessionOption $opt -OperationTimeoutSec 15 -ErrorAction Stop
        } else { $s = New-CimSession -ComputerName $pcHost -SessionOption $opt -OperationTimeoutSec 15 -ErrorAction Stop }
        foreach ($p in @(Get-CimInstance -CimSession $s Win32_Process -Filter "Name='$program'" -OperationTimeoutSec 15)) {
            [void](Invoke-CimMethod -InputObject $p -MethodName Terminate -OperationTimeoutSec 15)
        }
        Start-Sleep -Seconds 2
        if ($spArgs) { $act = New-ScheduledTaskAction -Execute $spPath -Argument $spArgs -WorkingDirectory $spDir }
        else { $act = New-ScheduledTaskAction -Execute $spPath -WorkingDirectory $spDir }
        $prin = New-ScheduledTaskPrincipal -UserId $spUser -LogonType Interactive -RunLevel Limited
        # Sin límite de tiempo: si no, Windows cerraría la app a los 3 días
        $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        [void](Register-ScheduledTask -CimSession $s -TaskName "GestorIT - Abrir $app" -Action $act -Principal $prin -Settings $set -Force)
        Start-ScheduledTask -CimSession $s -TaskName "GestorIT - Abrir $app"
        Start-Sleep -Seconds 6
        @{ Ok = $true; Msg = '' }
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        @{ Ok = $false; Msg = $e.Message }
    } finally { if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue } }
}

$BufRebootScript = {
    param($pcHost, $user, $pass)
    $s = $null
    try {
        $opt = New-CimSessionOption -Protocol Dcom
        if ($user) {
            $cred = New-Object Management.Automation.PSCredential($user, (ConvertTo-SecureString $pass -AsPlainText -Force))
            $s = New-CimSession -ComputerName $pcHost -Credential $cred -SessionOption $opt -OperationTimeoutSec 15 -ErrorAction Stop
        } else { $s = New-CimSession -ComputerName $pcHost -SessionOption $opt -OperationTimeoutSec 15 -ErrorAction Stop }
        $os = Get-CimInstance -CimSession $s Win32_OperatingSystem -OperationTimeoutSec 15
        $res = Invoke-CimMethod -InputObject $os -MethodName Win32Shutdown -Arguments @{ Flags = 6 } -OperationTimeoutSec 15   # 6 = reiniciar forzando
        if ($res.ReturnValue -ne 0) { throw "Windows ha devuelto el código $($res.ReturnValue)" }
        @{ Ok = $true; Msg = '' }
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        @{ Ok = $false; Msg = $e.Message }
    } finally { if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue } }
}

$BufServerScript = {
    param($h)
    foreach ($p in 443, 80) {
        $c = New-Object Net.Sockets.TcpClient
        try { $i = $c.BeginConnect($h, $p, $null, $null); if ($i.AsyncWaitHandle.WaitOne(2000)) { $c.EndConnect($i); return $true } } catch { } finally { $c.Close() }
    }
    $false
}

function Start-BufJob($kind, $buf, $script, [object[]]$argList) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:BufPool
    [void]$ps.AddScript($script)
    foreach ($a in $argList) { [void]$ps.AddArgument($a) }
    [void]$script:BufJobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Buf = $buf; Kind = $kind; Started = Get-Date })
    $BufTimer.Start()
}

function Sync-Buffers {
    $names = @{}
    foreach ($c in $script:Pcs) {
        if (-not $KioskOn -or $c.Name -notlike "$KioskPrefix*" -or -not $c.Enabled) { continue }
        $names[$c.Name] = $true
        if (-not @($script:Buffers | Where-Object { $_.Name -eq $c.Name }).Count) {
            $b = New-Object BufferPc; $b.Name = $c.Name; $b.Host = $c.Host
            $script:Buffers.Add($b)
        }
    }
    foreach ($b in @($script:Buffers)) { if (-not $names.ContainsKey($b.Name)) { [void]$script:Buffers.Remove($b) } }
    if ($script:BufNav.Count -eq 0) {
        $script:BufNav.Add((New-Nav 'buffers' 'all' 'Todas' $KioskTitle 0))
        $script:BufNav.Add((New-Nav 'buffers' 'issues' 'Con problemas' "$KioskTitle con problemas" 0))
    }
    Update-Counts
}

function Test-Buffers($list) {
    if (-not $script:Conn) { return }
    $u = $script:Conn.User; $p = $script:Conn.Pass
    if ($BufServerHost -and -not @($script:BufJobs | Where-Object { $_.Kind -eq 'server' }).Count) {
        $script:BufServer = $null
        Start-BufJob 'server' $null $BufServerScript @($BufServerHost)
    }
    foreach ($b in @($list)) {
        if ($b.Busy -or @($script:BufJobs | Where-Object { $_.Buf -eq $b }).Count) { continue }
        $b.Estado = 'checking'; $b.NotifyAll()
        Start-BufJob 'check' $b $BufCheckScript @($b.Host, $u, $p, $KioskProgram, $KioskApp)
    }
    Update-StatusBar
}

function Invoke-BufAction($b, [string]$action) {
    if (-not $b -or -not $script:Conn) { return }
    $u = $script:Conn.User; $p = $script:Conn.Pass
    switch ($action) {
        'rdp' { [void](Connect-Rdp $b.Host '' $true $false $false ('kiosk-' + $b.Name)); return }
        'ps'  { Connect-PsRemote $b.Host $b.Name; return }
        'sp' {
            if (-not $b.SpPath) { Show-Error "No sé dónde está $KioskProgram en $($b.Name). Se aprende la primera vez que se le ve abierto."; return }
            $b.Busy = $true; $b.Estado = 'busy'; $b.Detalle = "Cerrando y volviendo a abrir $KioskApp…"; $b.NotifyAll()
            Start-BufJob 'sp' $b $BufRestartSpScript @($b.Host, $u, $p, $b.SpPath, $b.SpArgs, $b.SpDir, $b.SpUser, $KioskProgram, $KioskApp)
        }
        'reboot' {
            $r = [Windows.MessageBox]::Show($Window, "¿Reiniciar $($b.Name)?`n`nLa pantalla se quedará unos minutos sin dashboard.", 'Reiniciar pantalla', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
            $b.Busy = $true; $b.Estado = 'busy'; $b.Detalle = 'Enviando la orden de reinicio…'; $b.NotifyAll()
            Start-BufJob 'reboot' $b $BufRebootScript @($b.Host, $u, $p)
        }
    }
}

$BufTimer = New-Object System.Windows.Threading.DispatcherTimer
$BufTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$BufTimer.Add_Tick({
    $changed = $false
    foreach ($j in @($script:BufJobs)) {
        $done = $j.Handle.IsCompleted
        $late = -not $done -and $j.Kind -eq 'check' -and ((Get-Date) - $j.Started) -gt $BufTimeout
        if (-not $done -and -not $late) { continue }
        $r = $null
        if ($done) { try { $r = $j.PS.EndInvoke($j.Handle) | Select-Object -Last 1 } catch { $r = $null }; $j.PS.Dispose() }
        else { try { [void]$j.PS.BeginStop($null, $null) } catch { } }
        [void]$script:BufJobs.Remove($j)
        $b = $j.Buf
        switch ($j.Kind) {
            'server' { $script:BufServer = [bool]$r }
            'check' {
                if ($late) { $b.Estado = 'noaccess'; $b.Detalle = "Responde en la red pero no contesta a la consulta en $([int]$BufTimeout.TotalSeconds) s" }
                elseif ($r) {
                    $b.Estado = $r.Estado; $b.Detalle = $r.Det; $b.User = $r.User; $b.Boot = $r.Boot; $b.SpSince = $r.SpSince
                    # La ruta de la app se recuerda aunque luego esté cerrada, para poder volver a abrirla
                    if ($r.SpPath) { $b.SpPath = $r.SpPath; $b.SpArgs = $r.SpArgs; $b.SpDir = $r.SpDir }
                    if ($r.SpUser) { $b.SpUser = $r.SpUser }
                } else { $b.Estado = 'noaccess'; $b.Detalle = 'La consulta no ha devuelto nada' }
                $b.NotifyAll()
            }
            'sp' {
                $b.Busy = $false
                if ($r -and $r.Ok) { Set-Status "$KioskApp reiniciado en $($b.Name)." }
                else { $b.Estado = 'noaccess'; $b.Detalle = "No se ha podido reiniciar ${KioskApp}: $(if ($r) { $r.Msg } else { 'sin respuesta' })"; $b.NotifyAll() }
                Test-Buffers @($b)
            }
            'reboot' {
                $b.Busy = $false
                if ($r -and $r.Ok) {
                    $b.Estado = 'off'; $b.Detalle = 'Reiniciando… Pulsa Comprobar en un par de minutos'; $b.Boot = $null; $b.SpSince = $null
                    Set-Status "Reiniciando $($b.Name)."
                } else { $b.Estado = 'noaccess'; $b.Detalle = "No se ha podido reiniciar: $(if ($r) { $r.Msg } else { 'sin respuesta' })" }
                $b.NotifyAll()
            }
        }
        $changed = $true
    }
    if (@($script:BufJobs | Where-Object { $_.Kind -eq 'check' }).Count -eq 0 -and $changed) { $script:BufChecked = Get-Date }
    if ($script:BufJobs.Count -eq 0) { $BufTimer.Stop() }
    if ($changed) {
        Update-Counts
        if ($script:Section -eq 'buffers') { Update-BuffersView }
        Update-StatusBar
    }
})

function Update-BuffersView {
    $q = $TxtSearch.Text.Trim()
    $script:BufView.Clear()
    foreach ($b in ($script:Buffers | Sort-Object Name)) {
        if ($script:BufFilter -eq 'issues' -and -not $b.IsProblem) { continue }
        if (-not (Test-Search $q @($b.Name, $b.User, $b.Detalle, $b.EstadoText))) { continue }
        $script:BufView.Add($b)
    }
    $ok = @($script:Buffers | Where-Object { $_.Estado -eq 'ok' }).Count
    $TxtSubtitle.Text = "$ok de $($script:Buffers.Count) operativos"
    if ($script:BufServer -eq $false) { $TxtSubtitle.Text += "  ·  ¡el servidor de $KioskApp no responde!" }
    elseif ($script:BufServer -eq $true) { $TxtSubtitle.Text += "  ·  servidor de $KioskApp OK" }
    $m = Get-DomainMsg 'las pantallas'
    if ($m) { Set-Msg $BufMsg $BufMsgTitle $BufMsgText $m[0] $m[1] }
    elseif ($script:Buffers.Count -eq 0) { Set-Msg $BufMsg $BufMsgTitle $BufMsgText 'No hay pantallas' "No hay equipos $KioskPrefix* habilitados en el dominio." }
    elseif ($script:BufView.Count -eq 0 -and $script:BufFilter -eq 'issues') { Set-Msg $BufMsg $BufMsgTitle $BufMsgText 'Todo en orden' 'Ningún buffer tiene problemas en la última revisión.' }
    elseif ($script:BufView.Count -eq 0) { Set-Msg $BufMsg $BufMsgTitle $BufMsgText 'Ningún buffer coincide' 'Prueba con otra búsqueda.' }
    else { Set-Msg $BufMsg $BufMsgTitle $BufMsgText $null $null }
}

function Update-View {
    if ($script:CurrentNav) { $TxtTitle.Text = $script:CurrentNav.Title }
    switch ($script:Section) {
        'servers' { Update-ServersView }
        'pcs'     { Update-PcView }
        'users'   { Update-UsersView }
        'buffers' { Update-BuffersView }
    }
}

function Show-Detail {
    $u = $UserList.SelectedItem
    $Detail.DataContext = $u
    if ($u) { $Detail.Visibility = 'Visible'; $DetailEmpty.Visibility = 'Collapsed' }
    else    { $Detail.Visibility = 'Collapsed'; $DetailEmpty.Visibility = 'Visible' }
}

function Update-StatusBar {
    switch ($script:Section) {
        'servers' {
            $on  = @($script:Servers | Where-Object { $_.Status -eq 'online' }).Count
            $off = @($script:Servers | Where-Object { $_.Status -eq 'offline' }).Count
            $t = Format-Count $script:Servers.Count 'servidor' 'servidores'
            if ($on -or $off) { $t += ", $on en línea y $off sin respuesta" }
            $t += '.'
            if ($script:SrvChecked) { $t += ' Última comprobación a las {0:HH:mm}.' -f $script:SrvChecked }
        }
        'pcs' {
            if (-not $script:LoadedAt) { $t = 'Sin datos del dominio.' }
            else {
                $on  = @($script:Pcs | Where-Object { $_.Status -eq 'online' }).Count
                $chk = @($script:Pcs | Where-Object { $_.Status -eq 'checking' }).Count
                $t = (Format-Count $script:Pcs.Count 'equipo' 'equipos') + " de $($script:DomainName), $on con escritorio remoto disponible."
                $who = @($script:Pcs | Where-Object { $_.SessionState -eq 'user' }).Count
                $t += " $who con alguien conectado."
                $sch = @($script:Pcs | Where-Object { $_.SessionState -eq 'checking' }).Count
                if ($chk -or $sch) { $t += " Comprobando $([Math]::Max($chk, $sch))…" }
            }
        }
        'users' {
            if (-not $script:LoadedAt) { $t = 'Sin datos del dominio.' }
            else { $t = '{0} leídos de {1} a las {2:HH:mm}.' -f (Format-Count $script:Users.Count 'usuario' 'usuarios'), $script:DomainName, $script:LoadedAt }
        }
        'buffers' {
            $chk = @($script:BufJobs | Where-Object { $_.Kind -eq 'check' }).Count
            $ok  = @($script:Buffers | Where-Object { $_.Estado -eq 'ok' }).Count
            $bad = @($script:Buffers | Where-Object { $_.IsProblem }).Count
            $t = "$ok operativos y $bad con problemas."
            if ($chk) { $t = "Revisando $chk pantallas…" }
            elseif ($script:BufChecked) { $t += ' Última revisión a las {0:HH:mm}.' -f $script:BufChecked }
            else { $t = 'Sin revisar. Pulsa Comprobar o F5.' }
        }
    }
    if ($script:LoadJob) { $t = 'Leyendo equipos y usuarios del dominio…' }
    $TxtStatus.Text = $t
}

function Update-Header {
    $sec = $script:Section
    $PanelServers.Visibility = if ($sec -eq 'servers') { 'Visible' } else { 'Collapsed' }
    $PanelPcs.Visibility     = if ($sec -eq 'pcs')     { 'Visible' } else { 'Collapsed' }
    $PanelUsers.Visibility   = if ($sec -eq 'users')   { 'Visible' } else { 'Collapsed' }
    $PanelBuffers.Visibility = if ($sec -eq 'buffers') { 'Visible' } else { 'Collapsed' }
    $BtnAdd.Visibility    = if ($sec -eq 'servers') { 'Visible' } else { 'Collapsed' }
    $BtnCheck.Visibility  = if ($sec -ne 'users')   { 'Visible' } else { 'Collapsed' }
    $BtnReload.Visibility = if ($sec -ne 'servers') { 'Visible' } else { 'Collapsed' }
    $BtnExport.Visibility = if ($sec -in 'pcs', 'users') { 'Visible' } else { 'Collapsed' }
    $BtnNewUser.Visibility = if ($sec -eq 'users') { 'Visible' } else { 'Collapsed' }
    Update-PcActions
    $SearchHint.Text = switch ($sec) {
        'servers' { 'Buscar servidor, IP o usuario' }
        'pcs'     { 'Buscar equipo, sistema o descripción' }
        'users'   { 'Buscar nombre, usuario, correo o departamento' }
        'buffers' { 'Buscar pantalla o estado' }
    }
    $SearchHint.Visibility = if ($TxtSearch.Text) { 'Collapsed' } else { 'Visible' }
}

function Select-Nav([NavItem]$item) {
    if (-not $item) { return }
    $script:NavGuard = $true
    $owner = switch ($item.Section) { 'servers' { $NavServers } 'pcs' { $NavPcs } 'users' { $NavUsers } 'buffers' { $NavBuffers } }
    foreach ($lb in @($NavServers, $NavPcs, $NavUsers, $NavBuffers)) { if ($lb -ne $owner) { $lb.SelectedIndex = -1 } }
    $owner.SelectedItem = $item
    $changed = $script:Section -ne $item.Section
    $script:Section = $item.Section
    $script:CurrentNav = $item
    switch ($item.Section) {
        'servers' { $script:SrvGroup = $item.Key }
        'pcs'     { $script:PcFilter = $item.Key }
        'users'   { $script:UserFilter = $item.Key }
        'buffers' { $script:BufFilter = $item.Key }
    }
    if ($changed) { $TxtSearch.Text = '' }
    $script:NavGuard = $false
    Update-Header
    Update-View
    Update-StatusBar
    # Al entrar en Buffers por primera vez, se revisan solos
    if ($item.Section -eq 'buffers' -and -not $script:BufChecked -and -not $script:BufJobs.Count) { Test-Buffers $script:Buffers }
}

# ---------------------------------------------------------------- Exportar
function Export-View {
    if ($script:Section -eq 'pcs')   { $rows = $script:PcView;   $base = 'equipos-ad' }
    else                             { $rows = $script:UserView; $base = 'usuarios-ad' }
    if ($rows.Count -eq 0) { Set-Status 'No hay nada en la vista para exportar.'; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV para Excel (*.csv)|*.csv'
    $dlg.FileName = '{0}-{1:yyyyMMdd}.csv' -f $base, (Get-Date)
    if (-not $dlg.ShowDialog($Window)) { return }
    try {
        if ($script:Section -eq 'pcs') {
            $data = $rows | ForEach-Object {
                [pscustomobject][ordered]@{
                    'Equipo'           = $_.Name
                    'Nombre DNS'       = $_.Host
                    'Sistema'          = $_.Os
                    'Familia'          = $_.Family
                    'Descripción'      = $_.Description
                    'Último inicio'    = $(if ($_.LastLogon) { $_.LastLogon.ToString('dd/MM/yyyy') } else { 'Nunca' })
                    'Conectado ahora'  = $(if ($_.SessionState -eq 'user') { $_.SessionUser } else { $_.SessionText })
                    'Habilitado'       = $(if ($_.Enabled) { 'Sí' } else { 'No' })
                    'Escritorio remoto' = switch ($_.Status) { 'online' { 'Responde' } 'offline' { 'No responde' } default { 'Sin comprobar' } }
                }
            }
        } else {
            $data = $rows | ForEach-Object {
                [pscustomobject][ordered]@{
                    'Nombre'              = $_.Name
                    'Usuario'             = $_.Sam
                    'Correo'              = $_.Mail
                    'Cargo'               = $_.Title
                    'Departamento'        = $_.Department
                    'Estado'              = $_.StatusText
                    'Último acceso'       = $_.LastLogonFull
                    'Contraseña cambiada' = $_.PwdLastSetText
                    'Contraseña caduca'   = $_.PwdExpiresText
                    'Creada'              = $_.CreatedText
                    'Grupos'              = ($_.Groups -join ', ')
                }
            }
        }
        $data | Export-Csv -Path $dlg.FileName -Delimiter ';' -NoTypeInformation -Encoding UTF8
        Set-Status "Exportadas $($rows.Count) filas a $($dlg.FileName)."
    } catch { Show-Error "No se ha podido guardar el archivo.`n`n$($_.Exception.Message)" }
}

# ---------------------------------------------------------------- Eventos: ventana
function Switch-Maximize { $Window.WindowState = if ($Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } }
$DragHandler = {
    param($sender, $e)
    if ($e.ClickCount -eq 2 -and $sender -eq $TitleBar) { Switch-Maximize; return }
    try { $Window.DragMove() } catch { }
}
$TitleBar.Add_MouseLeftButtonDown($DragHandler)
$Brand.Add_MouseLeftButtonDown($DragHandler)
$BtnMin.Add_Click({ $Window.WindowState = 'Minimized' })
$BtnMax.Add_Click({ Switch-Maximize })
$BtnClose.Add_Click({ $Window.Close() })
$Window.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height + 2
$Window.Add_StateChanged({
    if ($Window.WindowState -eq 'Maximized') {
        $Root.CornerRadius = 0; $Root.BorderThickness = 0
        $BtnMax.Content.Text = [string][char]0xE923
    } else {
        $Root.CornerRadius = 12; $Root.BorderThickness = 1
        $BtnMax.Content.Text = [string][char]0xE922
    }
})

# ---------------------------------------------------------------- Eventos: navegación y cabecera
$NavHandler = {
    param($sender, $e)
    if ($script:NavGuard) { return }
    if ($sender.SelectedItem) { Select-Nav $sender.SelectedItem }
}
$NavServers.Add_SelectionChanged($NavHandler)
$NavPcs.Add_SelectionChanged($NavHandler)
$NavUsers.Add_SelectionChanged($NavHandler)
$NavBuffers.Add_SelectionChanged($NavHandler)
$BufList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
    if (-not $btn) { return }
    $b = $btn.DataContext -as [BufferPc]
    if ($b) { Invoke-BufAction $b ([string]$btn.Tag) }
})

$TxtSearch.Add_TextChanged({
    $SearchHint.Visibility = if ($TxtSearch.Text) { 'Collapsed' } else { 'Visible' }
    if (-not $script:NavGuard) { Update-View }
})

$BtnAdd.Add_Click({ Show-Editor $null })
$BtnCheck.Add_Click({
    if ($script:Section -eq 'buffers') { Test-Buffers $script:Buffers; return }
    if ($script:Section -eq 'servers') { Test-Targets $script:Servers }
    else { Test-Targets ($script:PcView | Where-Object { $_.Enabled }); Test-Sessions $script:PcView }
})
$BtnReload.Add_Click({ if ($script:Conn) { Start-Load $script:Conn } else { Show-Conn $null } })
$BtnExport.Add_Click({ Export-View })
$BtnRetire.Add_Click({ Invoke-RetirePcs })
$BtnRestore.Add_Click({ Invoke-RestorePcs })
$BtnPurge.Add_Click({ Invoke-PurgePcs })
$PcList.Add_SelectionChanged({ Update-PcActions })
$BtnNewUser.Add_Click({ Show-NewUser $UserList.SelectedItem })
$BtnCloneUser.Add_Click({ Show-NewUser $Detail.DataContext })
$NuCancel.Add_Click({ Hide-NewUser })
$NuSave.Add_Click({ Save-NewUser })
$NuBackdrop.Add_MouseLeftButtonDown({ Hide-NewUser })
$NuGen.Add_Click({ $NuPass.Text = New-RandomPassword })
$NuCopy.Add_Click({ try { [Windows.Clipboard]::SetText($NuPass.Text); Set-Status 'Contraseña copiada al portapapeles.' } catch { } })
$NuFirst.Add_TextChanged({ Update-NewUserAuto })
$NuLast.Add_TextChanged({ Update-NewUserAuto })
$NuSam.Add_TextChanged({ if (-not $script:AutoFill) { $script:SamTouched = $true; Update-NewUserAuto } })
$NuMail.Add_TextChanged({ if (-not $script:AutoFill) { $script:MailTouched = $true } })
$BtnConn.Add_Click({ Show-Conn $null })

# ---------------------------------------------------------------- Eventos: servidores
$Cards.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
    if (-not $btn) { return }
    $s = $btn.DataContext -as [RdpServer]
    if (-not $s) { return }
    switch ([string]$btn.Tag) {
        'connect' { Connect-Server $s }
        'edit'    { Show-Editor $s }
        'ps'      { Connect-PsRemote $s.Host $s.Name }
        'delete'  { Remove-Server $s }
    }
})
$Cards.AddHandler([System.Windows.UIElement]::MouseLeftButtonDownEvent, [System.Windows.Input.MouseButtonEventHandler]{
    param($sender, $e)
    if ($e.ClickCount -ne 2) { return }
    $fe = $e.OriginalSource -as [System.Windows.FrameworkElement]
    if (-not $fe) { return }
    $s = $fe.DataContext -as [RdpServer]
    if ($s) { Connect-Server $s; $e.Handled = $true }
})

$EdCancel.Add_Click({ Hide-Editor })
$EdRdp.Add_Checked({ Set-EditorProto 'rdp' })
$EdSsh.Add_Checked({ Set-EditorProto 'ssh' })
$EdSave.Add_Click({ Save-Editor })
$Backdrop.Add_MouseLeftButtonDown({ Hide-Editor })

# ---------------------------------------------------------------- Eventos: equipos
$PcList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
    if (-not $btn) { return }
    $c = $btn.DataContext -as [AdComputer]
    if (-not $c) { return }
    switch ([string]$btn.Tag) {
        'connect' { Connect-Pc $c }
        'ps'      { Connect-PsRemote $c.Host $c.Name }
    }
})
$PcList.AddHandler([System.Windows.UIElement]::MouseLeftButtonDownEvent, [System.Windows.Input.MouseButtonEventHandler]{
    param($sender, $e)
    if ($e.ClickCount -ne 2) { return }
    $fe = $e.OriginalSource -as [System.Windows.FrameworkElement]
    if (-not $fe) { return }
    $c = $fe.DataContext -as [AdComputer]
    if ($c) { Connect-Pc $c; $e.Handled = $true }
})

# ---------------------------------------------------------------- Eventos: usuarios
$UserList.Add_SelectionChanged({ Show-Detail })

$BtnUnlock.Add_Click({
    $u = $Detail.DataContext; if (-not $u) { return }
    $err = Invoke-AdAction $u { param($up) $up.UnlockAccount() }
    if ($err) { Show-Error "No se ha podido desbloquear a $($u.Name).`n`n$err"; return }
    Update-OneUser $u
    Set-Status "Cuenta de $($u.Name) desbloqueada."
})

$BtnToggle.Add_Click({
    $u = $Detail.DataContext; if (-not $u) { return }
    if ($u.Enabled) {
        $r = [Windows.MessageBox]::Show($Window, "¿Deshabilitar la cuenta de $($u.Name)?`n`nNo podrá iniciar sesión hasta que la vuelvas a habilitar.", 'Deshabilitar cuenta', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        $err = Invoke-AdAction $u { param($up) $up.Enabled = $false; $up.Save() }
        $done = "Cuenta de $($u.Name) deshabilitada."
    } else {
        $err = Invoke-AdAction $u { param($up) $up.Enabled = $true; $up.Save() }
        $done = "Cuenta de $($u.Name) habilitada."
    }
    if ($err) { Show-Error "No se ha podido cambiar la cuenta de $($u.Name).`n`n$err"; return }
    Update-OneUser $u
    Set-Status $done
})

$BtnReset.Add_Click({ Show-Reset })
$RsGen.Add_Click({ $RsPass.Text = New-RandomPassword })
$RsCopy.Add_Click({ try { [Windows.Clipboard]::SetText($RsPass.Text); Set-Status 'Contraseña copiada al portapapeles.' } catch { } })
$RsCancel.Add_Click({ Hide-Reset })
$RsSave.Add_Click({ Save-Reset })
$ResetBackdrop.Add_MouseLeftButtonDown({ Hide-Reset })

# ---------------------------------------------------------------- Eventos: conexión
$SyncCreds = {
    $on = -not [bool]$CnCurrent.IsChecked
    $CnCreds.IsEnabled = $on
    $CnCreds.Opacity = if ($on) { 1 } else { 0.4 }
}
$CnCurrent.Add_Checked($SyncCreds)
$CnCurrent.Add_Unchecked($SyncCreds)
$CnConnect.Add_Click({ Submit-Conn })
$CnCancel.Add_Click({ $ConnOverlay.Visibility = 'Collapsed' })

# ---------------------------------------------------------------- Teclado
$Window.Add_PreviewKeyDown({
    param($sender, $e)
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
    if ($Overlay.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape') { Hide-Editor; $e.Handled = $true }
        elseif ($e.Key -eq 'Return' -and -not $EdNotes.IsKeyboardFocused) { Save-Editor; $e.Handled = $true }
        return
    }
    if ($IpOverlay.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape') { $IpOverlay.Visibility = 'Collapsed'; $e.Handled = $true }
        elseif ($e.Key -eq 'Return') { Start-IpSearch; $e.Handled = $true }
        return
    }
    if ($NewUserOverlay.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape') { Hide-NewUser; $e.Handled = $true }
        elseif ($e.Key -eq 'Return') { Save-NewUser; $e.Handled = $true }
        return
    }
    if ($ResetOverlay.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape') { Hide-Reset; $e.Handled = $true }
        elseif ($e.Key -eq 'Return') { Save-Reset; $e.Handled = $true }
        return
    }
    if ($ConnOverlay.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape') { $ConnOverlay.Visibility = 'Collapsed'; $e.Handled = $true }
        elseif ($e.Key -eq 'Return') { Submit-Conn; $e.Handled = $true }
        return
    }
    if ($ctrl) {
        switch ($e.Key) {
            { $_ -in 'D1', 'NumPad1' } { Select-Nav $script:SrvNav[0];  $e.Handled = $true }
            { $_ -in 'D2', 'NumPad2' } { Select-Nav $script:PcNav[0];   $e.Handled = $true }
            { $_ -in 'D3', 'NumPad3' } { Select-Nav $script:UserNav[0]; $e.Handled = $true }
            { $_ -in 'D4', 'NumPad4' } { if ($KioskOn -and $script:BufNav.Count) { Select-Nav $script:BufNav[0] }; $e.Handled = $true }
            'N' { Select-Nav $script:SrvNav[0]; Show-Editor $null; $e.Handled = $true }
            'F' { [void]$TxtSearch.Focus(); $TxtSearch.SelectAll(); $e.Handled = $true }
            'I' { Show-IpSearch $null; $e.Handled = $true }
        }
        return
    }
    if ($e.Key -eq 'F5') {
        switch ($script:Section) {
            'servers' { Test-Targets $script:Servers }
            'pcs'     { Test-Targets ($script:PcView | Where-Object { $_.Enabled }); Test-Sessions $script:PcView }
            'users'   { if ($script:Conn) { Start-Load $script:Conn } }
            'buffers' { Test-Buffers $script:Buffers }
        }
        $e.Handled = $true
    }
    elseif ($e.Key -eq 'Escape' -and $TxtSearch.Text) { $TxtSearch.Text = ''; $e.Handled = $true }
})

$Window.Add_Closed({
    $PollTimer.Stop(); $AutoTimer.Stop(); $LoadTimer.Stop(); $BufTimer.Stop()
    foreach ($j in @($script:BufJobs)) { try { [void]$j.PS.BeginStop($null, $null) } catch { } }
    foreach ($j in @($script:Jobs)) { try { [void]$j.PS.BeginStop($null, $null) } catch { } }
    if ($script:LoadJob) { try { $script:LoadJob.PS.Stop(); $script:LoadJob.PS.Dispose() } catch { } }
    $script:Pool.Close(); $script:Pool.Dispose()
    try { $script:SessPool.Close(); $script:SessPool.Dispose() } catch { }
    $script:Conn = $null; $script:Pending = $null
})

# ---------------------------------------------------------------- Arranque
Import-Servers
Update-ServerNav
Sync-Buffers
Update-Counts
Select-Nav $script:SrvNav[0]
$Window.Add_ContentRendered({
    Test-Targets $script:Servers
    $AutoTimer.Start()
    $saved = Get-DomainLogin
    if ($saved) {
        $CnServer.Text = $saved.Server; $CnUser.Text = [string]$saved.User
        $CnCurrent.IsChecked = -not $saved.User; $CnRemember.IsChecked = $true
        Start-Load $saved
    }
    elseif ($env:USERDNSDOMAIN) { Start-Load @{ Server = ''; User = $null; Pass = $null; Remember = $false } }
})
$Window.WindowState = 'Normal'
$Window.Add_SourceInitialized({ $Window.WindowState = 'Normal' })
$Window.Add_Loaded({ $Window.WindowState = 'Normal'; [void]$Window.Activate() })
# Un error mientras se usa la app se avisa, pero la app sigue abierta
$Window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    $e.Handled = $true
    $m = $e.Exception; while ($m.InnerException) { $m = $m.InnerException }
    try { Add-Content -Path $ErrorLog -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}`r`n" -f (Get-Date), $m.Message) } catch { }
    [Windows.MessageBox]::Show($Window, "Algo ha fallado, pero puedes seguir usando la app.`n`n$($m.Message)", 'Gestor IT', 'OK', 'Warning') | Out-Null
})
[void]$Window.ShowDialog()
# Cierra del todo aunque quede alguna consulta colgada en segundo plano
[Environment]::Exit(0)
