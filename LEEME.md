# Sistema Andes de venta de boletos

## Acceso con HTTPS en PC y celular

1. Conecta la computadora y el celular a la misma red Wi‑Fi.
2. Ejecuta una vez `Configurar acceso WiFi.cmd` y autoriza el aviso de administrador. Configura HTTPS en el puerto 443 e instala la autoridad raíz local en Windows.
3. Inicia `Iniciar sistema WiFi.cmd` y deja abierta la ventana del servidor.
4. En la computadora abre el enlace HTTPS que muestra el configurador.
5. En Android, descarga primero el certificado público desde `http://<IP-de-la-PC>:4180/andes-lan-root.cer`. En Ajustes busca **Instalar un certificado** y selecciona el archivo como **certificado de CA**. Después abre el enlace HTTPS en Chrome.

El certificado raíz es local y no está firmado por una autoridad pública. Se debe instalar manualmente en el celular para que el navegador confíe en el HTTPS. La huella SHA‑256 del certificado aparece en la ventana del configurador.

Si cambia la red o la dirección IP, vuelve a ejecutar `Configurar acceso WiFi.cmd`. El enlace HTTP anterior redirige al HTTPS; en ambos dispositivos usa la misma dirección `https://<IP-de-la-PC>/`.

En un celular, **☰** abre las secciones de administración; **Vista cliente / Vista administrador** cambia de modo; **↻** recarga la página.

Las reservas y compras se sincronizan mediante el servidor local. Las reservas vencen a los 10 minutos y el servidor impide reservar el mismo asiento desde dos dispositivos a la vez.
