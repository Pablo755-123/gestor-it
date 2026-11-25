# Gestor IT

Una app de escritorio para Windows que junta en una sola ventana el día a día de un técnico de sistemas: servidores, equipos y usuarios del Directorio Activo, y las pantallas de dashboard de planta.

Está hecha en **PowerShell + WPF**. No necesita RSAT, ni instalar agentes en los servidores, ni permisos de administrador para instalarse.

> Nació en una planta industrial para dejar de saltar entre el escritorio remoto, la consola del AD, el navegador y el cuaderno de IPs.

## Qué hace

**Servidores**
- Tarjetas por grupos con su estado en tiempo real (comprueba el puerto cada 2 minutos).
- Conexión con un clic por **RDP**, **SSH** (en Windows Terminal) o **PowerShell remoto**.
- Las contraseñas no se guardan en la app: las de RDP las gestiona Windows y las de SSH las pide el propio SSH.

**Equipos del dominio**
- Lista de los PCs del Directorio Activo, filtrable por Windows 11, Windows 10, inactivos o deshabilitados.
- **Quién está conectado ahora** en cada equipo (en consola o por escritorio remoto).
- **Retirar** los equipos que llevan meses sin usarse: los deshabilita y los aparta a una unidad organizativa, y se pueden **reactivar** tal como estaban. Pasados 30 días se pueden **eliminar**, con aviso si se perdería una clave de BitLocker o LAPS.

**Usuarios del dominio**
- Desbloquear, habilitar o deshabilitar, y **restablecer contraseñas** (genera una legible y la copia al portapapeles).
- **Crear usuarios copiando a otro:** misma ubicación, mismo departamento y mismos grupos.
- Exportar a CSV.

**Pantallas de dashboard (opcional)**
- Para pantallas de planta que muestran un dashboard con un programa (un PC por pantalla, en sesión iniciada).
- Semáforo de cada pantalla: operativa, programa cerrado, pantalla bloqueada, sin sesión o apagada.
- Reabrir el programa o reiniciar el equipo en remoto.

**Identificar IP o equipo** (`Ctrl+I`)
- Escribe una IP o un nombre y te dice qué es: nombre DNS y Windows, MAC, puertos abiertos, modelo, sistema y quién tiene la sesión abierta. Si es un servidor tuyo o un PC del dominio, te lo dice por su nombre.
- Botones para abrir RDP, SSH, PowerShell, su web o buscarlo en NetBox.

## Requisitos

- Windows 10 u 11 con Windows PowerShell 5.1, que ya viene instalado.
- Un equipo unido al dominio, o una cuenta del dominio (la app puede recordarla cifrada con DPAPI).
- En los equipos que quieras consultar: **WMI** abierto en el firewall (para sesiones, pantallas y retirada) y **WinRM** para PowerShell remoto. La app ofrece activar WinRM al conectar si no lo está.
- Para gestionar usuarios y retirar equipos, la cuenta necesita permisos en el AD.

## Instalación

1. Entra en la [última versión](https://github.com/Pablo755-123/gestor-it/releases/latest), descarga **Source code (zip)** y descomprímelo.
2. Ejecuta **`Instalar.bat`**. Si Windows avisa de que viene de Internet: "Más información" > "Ejecutar de todas formas".
3. Al abrirse, si tu PC está en el dominio, se conecta sola. Si no, pulsa **Cambiar conexión** y escribe tu dominio y tu cuenta (`DOMINIO\usuario`). Marca "Recordar" y se guarda cifrada con Windows.

Ya está: añade tus servidores con **Añadir servidor** y a trabajar.

Opcional: antes de instalar, copia `config.example.json` como `config.json` y pon los datos de tu red (ver abajo) para tener una lista inicial de servidores, NetBox o la sección de pantallas. **Nunca pongas contraseñas en `config.json`**: no hacen falta.

Se instala en `%LOCALAPPDATA%\Programs\GestorIT`, crea accesos directos en el menú Inicio y en el escritorio, y se abre. Haz clic derecho en su icono de la barra de tareas y elige **Anclar a la barra de tareas**.

Para actualizar, vuelve a ejecutar `Instalar.bat`. Tus servidores y tu cuenta recordada, que están en `%APPDATA%\GestorIT`, no se tocan.

## Configuración (`config.json`)

| Clave | Para qué sirve |
|---|---|
| `DefaultController` | Dominio o IP de un controlador, para cuando el PC no está unido al dominio. |
| `NetBoxUrl` | Dirección de tu NetBox (por ejemplo `http://netbox.ejemplo.local`). Vacío = sin botón de NetBox. |
| `Kiosks.Enabled` | `true` para activar la sección de pantallas de dashboard. |
| `Kiosks.Title` | Nombre de la sección en la barra lateral (por ejemplo "Pantallas" o "Buffers"). |
| `Kiosks.Prefix` | Prefijo del nombre de esos equipos en el AD (por ejemplo `KIOSK-`). |
| `Kiosks.Program` | Ejecutable que muestra el dashboard (por ejemplo `Dashboard.exe`). |
| `Kiosks.AppName` | Cómo se llama ese programa en los textos de la app. |
| `Kiosks.Server` | Servidor que sirve el dashboard. Si se cae, se avisa arriba. Vacío = no se comprueba. |
| `DefaultServers` | Servidores con los que arranca la lista la primera vez. Cada uno: `Name`, `Host` y, opcionales, `Group`, `Notes`, `Protocol` (`rdp` o `ssh`), `Port` y `User`. |

`config.json` está en el `.gitignore`: nunca subas tu configuración real a un repositorio público.

## Atajos

| Tecla | Acción |
|---|---|
| `Ctrl+1` … `Ctrl+4` | Servidores, Equipos, Usuarios, Pantallas |
| `Ctrl+I` | Identificar IP o equipo |
| `Ctrl+N` | Añadir servidor |
| `Ctrl+F` | Buscar |
| `F5` | Comprobar o recargar la sección |

## Seguridad

- La app usa **tu** cuenta y tus permisos: no hace nada que no puedas hacer tú desde las consolas de Windows.
- La cuenta del dominio, si eliges recordarla, se guarda cifrada con DPAPI: solo tu usuario de Windows en ese PC puede descifrarla.
- Las acciones que no tienen vuelta atrás (eliminar equipos, reiniciar, deshabilitar cuentas) piden confirmación.

## Licencia

MIT. Úsala, cámbiala y compártela. Si la mejoras, se agradece un pull request.
