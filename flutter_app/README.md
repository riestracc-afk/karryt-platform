# Karryt Flutter (Migracion inicial)

Este modulo es la migracion inicial del frontend de Karryt a Flutter, conservando el backend Node/Express existente.

## Requisitos

- Flutter SDK 3.22+
- Backend Node corriendo en puerto 3000

## Ejecutar

1. Ir a la carpeta del modulo:
   - `cd flutter_app`
2. Instalar dependencias:
   - `flutter pub get`
3. Ejecutar app:
   - Web: `flutter run -d chrome`
   - Android: `flutter run -d android`
   - iOS: `flutter run -d ios`

## Conexion con API

La app apunta por defecto a:
- Web/iOS/desktop: `http://localhost:3000`
- Android emulador: `http://10.0.2.2:3000`

Si necesitas otro host, usa:
- `flutter run --dart-define=API_BASE_URL=http://TU_IP:3000`

## Alcance migrado

- Carga de categorias y servicios
- Cotizacion de tarifa
- Creacion de viaje
- Seguimiento de estado del viaje en tiempo real (Socket.IO)
- Cancelacion de viaje
- Tabla de tarifas por categoria
- Mapa en vivo de conductores (OpenStreetMap + flutter_map)
- Seleccion de origen/destino tocando el mapa
- Calculo automatico de distancia al marcar ambos puntos
- Boton de geolocalizacion real (Mi ubicacion) con manejo de permisos
- Geocodificacion inversa para mostrar direcciones legibles desde coordenadas
- Busqueda/autocompletado de direcciones (forward geocoding) para origen y destino
- Seleccion de resultados en lista y centrado automatico del mapa
- Historial de direcciones recientes para seleccion rapida
- Direcciones favoritas (guardar y reutilizar en origen/destino)
- Consola administrativa en Flutter para editar parametros y tarifas
- App de chofer en Flutter para gestionar disponibilidad y estados de viajes

## Navegacion

La app Flutter ahora integra los tres roles en una sola base:
- Usuario
- Admin
- Chofer

Usa la barra inferior principal para cambiar de modulo.

Dentro del modulo Usuario se mantiene la barra inferior interna para:
- Solicitar
- Mapa
- Tarifas

La barra interna de Usuario se sincroniza automaticamente con la seccion visible mientras desplazas la pantalla.

## Apps independientes por rol

Ahora cada rol tiene su punto de entrada propio, compartiendo la misma API y base de datos:

- Usuario: `lib/main_user.dart`
- Chofer: `lib/main_driver.dart`
- Admin (PC): `lib/main_admin.dart`

Desde la raiz del proyecto:

- `npm run run:user`
- `npm run run:driver`
- `npm run run:admin`

Para build web por rol:

- `npm run build:web:user`
- `npm run build:web:driver`
- `npm run build:web:admin`

Para empaquetar las 3 apps en un solo hosting compartido:

- `npm run build:web:multi`

Rutas de produccion esperadas:

- Usuario: `/`
- Chofer: `/chofer`
- Admin PC: `/admin`

Identidad visual separada por app (generada en build multi):

- Usuario: titulo `Karryt Usuario`, color base verde, favicon `U`
- Chofer: titulo `Karryt Chofer`, color base azul, favicon `C`
- Admin PC: titulo `Karryt Admin PC`, color base cobre, favicon `A`

## Favoritos sincronizados

Las direcciones favoritas se sincronizan con el backend en:
- `GET /api/address-favorites`
- `PUT /api/address-favorites`

La app mantiene una copia local de respaldo para seguir funcionando si el backend no responde.

## Recientes sincronizados

Las direcciones recientes también se sincronizan en:
- `GET /api/address-recents`
- `PUT /api/address-recents`

Esto permite reutilizar historial entre dispositivos y conserva un respaldo local por si la API no está disponible.

## Estructura

- `lib/core/`: configuracion base (API)
- `lib/domain/`: modelos de dominio
- `lib/data/`: cliente REST y cliente Socket.IO
- `lib/state/`: controlador de estado de la pantalla

## Nota

El frontend del proyecto es Flutter. Para despliegue web, compila con `flutter build web`.

