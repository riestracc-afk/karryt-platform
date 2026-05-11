# KARRIT - Plataforma de Conexión para Transporte de Carga

**KARRIT** es una plataforma web que conecta clientes con conductores especializados en transporte de carga. Ofrece 4 categorías de vehículos para cubrir desde cargas ligeras hasta transporte de granel con camiones especializados.

---

## 📋 Categorías de Vehículos

### 1️⃣ **Pick-up Mini** (Hasta 800 kg)
Vehículos compactos de carga ligera, ideales para paquetes y entregas rápidas.

**Vehículos disponibles:**
- Tornado
- Courier
- Montana
- RAM 700
- Fiat Strada
- Renault Oroch
- VW Saveiro

**Servicios:**
- Recorrido Local
- Recorrido Regional

---

### 2️⃣ **Especializada 1.1T** (Hasta 1.1 tonelada)
Camionetas especializadas con estructuras adaptadas para tipos específicos de carga.

**Especializaciones:**
- 📦 **Extaquita** - Para carga general en estructuras cerradas
- 📐 **Plataforma** - Para carga de volumen
- ⚙️ **Herrería** - Para metales y estructuras pesadas
- 🪟 **Cristales** - Para carga frágil y delicada
- 🪨 **Mármol** - Para materiales pétreos y pesados

**Vehículos disponibles:**
- Chevrolet D20
- Ford Ranger Compact
- Toyota Hilux Compact
- Nissan NP300

**Servicios:**
- Carga Frágil
- Carga Estructural

---

### 3️⃣ **Camión 3T** (Hasta 3 toneladas)
Camiones medianos para carga consolidada y transporte de volumen.

**Vehículos disponibles:**
- Hino 300
- Isuzu NQR
- Mercedes 815
- Iveco Tector
- Scania P112H

**Servicios:**
- Carga Estándar
- Carga Pesada

---

### 4️⃣ **Camión de Volteo** (Caja 6m³)
Camiones especializados para carga a granel y materiales sueltos.

**Vehículos disponibles:**
- Hino 500
- Volvo FM
- Scania P230
- MAN TGA
- Mercedes Axor

**Servicios:**
- Carga a Granel
- Carga Especializada

---

## 🚀 Características

✅ **Selección dinámica de categoría y servicio** - Interfaz guiada para elegir el vehículo perfecto  
✅ **Cotización en tiempo real** - Cálculo automático de tarifa basado en distancia  
✅ **Asignación automática de conductor** - Sistema de matching por categoría y proximidad  
✅ **Seguimiento en vivo** - Mapa simulado con ubicación de conductores disponibles  
✅ **Timeline del viaje** - Historial detallado de cada solicitud  
✅ **Cancelación segura** - Opción de cancelar antes de que inicie la carga  

---

## 📦 Stack Tecnológico

- **Backend:** Node.js + Express + Socket.io
- **Frontend:** HTML5 + CSS3 + JavaScript Vanilla
- **Base de datos:** En memoria (demo)
- **Transporte:** WebSockets para actualizaciones en vivo

---

## 🛠️ Instalación y Uso

### Requisitos
- Node.js 18+
- npm

### Instalación
```bash
cd "c:\Proyectos\Proyecto KARRIT"
npm install
```

### Ejecutar en desarrollo
```bash
npm run dev
```

### Ejecutar en producción
```bash
npm start
```

La aplicación estará disponible en: **http://localhost:3000**

---

## 📡 API Endpoints

### Obtener todas las categorías
```bash
GET /api/categories
```

Devuelve todas las categorías con vehículos y especificaciones.

### Obtener servicios de una categoría
```bash
GET /api/services/:category
```

Ejemplo: `GET /api/services/pickup_mini`

### Obtener cotización
```bash
GET /api/quote?category=pickup_mini&service=local&distance=10&waitMinutes=5
```

### Crear solicitud de carga
```bash
POST /api/rides
Content-Type: application/json

{
  "pickup": "Zona industrial 15",
  "dropoff": "Centro de distribución",
  "category": "pickup_mini",
  "service": "local",
  "pickupPoint": { "lat": 40.4168, "lng": -3.7038 }
}
```

### Obtener estado de un viaje
```bash
GET /api/rides/:id
```

### Cancelar un viaje
```bash
POST /api/rides/:id/cancel
```

---

## 💰 Modelo de Precios

Las tarifas varían según:
- **Categoría del vehículo** - Capacidad y especialización
- **Tipo de servicio** - Multiplicador de operación
- **Distancia** - Kilómetros a recorrer
- **Tiempo de espera** - Minutos de carga/descarga
- **Demanda** - Factor dinámico según disponibilidad

### Tarifas base activas por categoría (MXN)

| Categoría | Tarifa de arranque | Por km | Espera por minuto |
|-----------|--------------------|--------|-------------------|
| Pick-up Mini | $150 | $18 | $4 |
| Especializada 1.1T | $300 | $30 | $6 |
| Camión 3T | $700 | $45 | $8 |
| Camión de Volteo | $1500 | $75 | $12 |

El endpoint de cotización devuelve la tarifa estimada en **MXN** y también los campos `startFare`, `perKmRate` y `waitPerMinRate` de la categoría seleccionada.

---

## 🔒 Conformidad Legal

Esta plataforma fue desarrollada como demo educativa con enfoque en:

✓ **Código 100% original** - Sin clonación de competidores  
✓ **Identidad propia** - Marca KARRIT única y diferenciada  
✓ **Licencias claras** - Todas las dependencias con licencias permisivas (MIT/Apache)  
✓ **Preparado para GDPR** - Arquitectura lista para implementar privacidad  

---

## 📝 Cambios Realizados (Transformación de Uber-clone a KARRIT)

### Backend (server.js)
- ✅ Reemplazo de `serviceCatalog` genérico por `vehicleCategories` especializadas
- ✅ Implementación de 4 categorías con 20+ modelos de vehículos
- ✅ Servicios dinámicos por categoría (no fijos)
- ✅ Algoritmo de matching por categoría de vehículo
- ✅ 18 conductores demo con vehículos asignados
- ✅ Tracking de entregas completadas por conductor
- ✅ Endpoints `/api/categories` y `/api/services/:category`

### Frontend (HTML/CSS/JS)
- ✅ Rebranding visual: Paleta naranja/dorado (logística)
- ✅ Nuevo hero: "Tu Carga, Nuestro Servicio"
- ✅ Selector dinámico de categoría → Servicios
- ✅ Textos contextuales: "Solicitar Carga", "Entrega", "Conductor"
- ✅ Información enriquecida de conductor: Vehículo, entregas completadas
- ✅ Validaciones de flujo de selección

### Identidad
- ✅ Cambio `package.json`: "karrit-uber-clone" → "karrit-platform"
- ✅ Descripción: "Plataforma de conexión para conductores de camionetas y camiones"
- ✅ Logo mental: Naranja (carga, movimiento, energía)

---

## 🎯 Próximos Pasos Opcionales

1. **Autenticación** - Registro de conductores y clientes
2. **Pagos reales** - Integración con pasarela (Stripe, PayPal)
3. **Mapas reales** - Google Maps o Mapbox
4. **Panel de conductor** - App para aceptar/rechazar cargas
5. **Historial** - Base de datos persistente
6. **Ratings** - Sistema de calificaciones bidireccional
7. **Soporte 24/7** - Chat en vivo

---

## 📄 Licencia

MIT - Libre para uso educativo y comercial.

---

**KARRIT © 2026 - Conectando movimiento con eficiencia.**
