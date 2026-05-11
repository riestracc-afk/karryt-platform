const express = require("express");
const http = require("http");
const path = require("path");
const { Server } = require("socket.io");
const { v4: uuidv4 } = require("uuid");

const app = express();
const server = http.createServer(app);
const io = new Server(server);

const PORT = process.env.PORT || 3000;

app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

const cityCenter = { lat: 40.4168, lng: -3.7038 };

// Catálogo de categorías y vehículos KARRIT
const vehicleCategories = {
  pickup_mini: {
    id: "pickup_mini",
    label: "Pick-up Mini",
    capacity: "Hasta 800 kg",
    description: "Vehículos compactos de carga ligera",
    vehicles: [
      { id: "tornado", name: "Tornado" },
      { id: "courier", name: "Courier" },
      { id: "montana", name: "Montana" },
      { id: "ram700", name: "RAM 700" },
      { id: "fiat_strada", name: "Fiat Strada" },
      { id: "renault_oroch", name: "Renault Oroch" },
      { id: "vw_saveiro", name: "VW Saveiro" }
    ]
  },
  specialized_1t: {
    id: "specialized_1t",
    label: "Especializada 1.1T",
    capacity: "Hasta 1.1 tonelada",
    description: "Camionetas especializadas para carga estructurada",
    subtypes: [
      { id: "extaquita", name: "Extaquita", icon: "📦" },
      { id: "plataforma", name: "Plataforma", icon: "📐" },
      { id: "herreria", name: "Herrería", icon: "⚙️" },
      { id: "cristales", name: "Cristales", icon: "🪟" },
      { id: "marmol", name: "Mármol", icon: "🪨" }
    ],
    vehicles: [
      { id: "chevrolet_d20", name: "Chevrolet D20" },
      { id: "ford_ranger_compact", name: "Ford Ranger Compact" },
      { id: "toyota_hilux_compact", name: "Toyota Hilux Compact" },
      { id: "nissan_np300", name: "Nissan NP300" }
    ]
  },
  truck_3t: {
    id: "truck_3t",
    label: "Camión 3T",
    capacity: "Hasta 3 toneladas",
    description: "Camiones medianos para carga consolidada",
    vehicles: [
      { id: "hino_300", name: "Hino 300" },
      { id: "isuzu_nqr", name: "Isuzu NQR" },
      { id: "mercedes_815", name: "Mercedes 815" },
      { id: "iveco_tector", name: "Iveco Tector" },
      { id: "scania_p112h", name: "Scania P112H" }
    ]
  },
  dump_truck: {
    id: "dump_truck",
    label: "Camión de Volteo",
    capacity: "Caja 6m³",
    description: "Camiones especializados para carga a granel",
    vehicles: [
      { id: "hino_500", name: "Hino 500" },
      { id: "volvo_fm", name: "Volvo FM" },
      { id: "scania_p230", name: "Scania P230" },
      { id: "man_tga", name: "MAN TGA" },
      { id: "mercedes_axor", name: "Mercedes Axor" }
    ]
  }
};

// Catálogo de servicios por categoría (valores de referencia altos, MXN)
const serviceCatalog = {
  pickup_mini: {
    local: { label: "Recorrido Local", multiplier: 1 },
    regional: { label: "Recorrido Regional", multiplier: 1.05 }
  },
  specialized_1t: {
    fragile: { label: "Carga Frágil", multiplier: 1.02 },
    structural: { label: "Carga Estructural", multiplier: 1.08 }
  },
  truck_3t: {
    standard: { label: "Carga Estándar", multiplier: 1.03 },
    heavy: { label: "Carga Pesada", multiplier: 1.1 }
  },
  dump_truck: {
    bulk: { label: "Carga a Granel", multiplier: 1.04 },
    specialized: { label: "Carga Especializada", multiplier: 1.12 }
  }
};

// Tarifas base por categoría usando el valor más alto definido por negocio (MXN)
const categoryRateCard = {
  pickup_mini: {
    startFare: 150,
    perKm: 18,
    waitPerMin: 4
  },
  specialized_1t: {
    startFare: 300,
    perKm: 30,
    waitPerMin: 6
  },
  truck_3t: {
    startFare: 700,
    perKm: 45,
    waitPerMin: 8
  },
  dump_truck: {
    startFare: 1500,
    perKm: 75,
    waitPerMin: 12
  }
};

// Generar conductores con vehículos asignados
const drivers = Array.from({ length: 18 }, (_, i) => {
  const categories = Object.keys(vehicleCategories);
  const category = categories[i % categories.length];
  const categoryData = vehicleCategories[category];
  const vehicle = categoryData.vehicles[Math.floor(Math.random() * categoryData.vehicles.length)];

  return {
    id: `DRV-${1000 + i}`,
    name: [
      "Carlos Rodríguez", "María López", "Juan González", "Ana García", "Pedro Martínez",
      "Laura Fernández", "Roberto Díaz", "Sofía Romero", "Miguel Torres", "Patricia Ruiz",
      "José Morales", "Elena Castro", "Francisco Moreno", "Isabel Soto", "Diego Vargas",
      "Rosa Campos", "Andrés Rubio", "Beatriz Herrera"
    ][i],
    rating: (4.6 + Math.random() * 0.4).toFixed(2),
    category,
    vehicle: { id: vehicle.id, name: vehicle.name },
    capacity: categoryData.capacity,
    lat: cityCenter.lat + (Math.random() - 0.5) * 0.08,
    lng: cityCenter.lng + (Math.random() - 0.5) * 0.08,
    available: true,
    completedRides: Math.floor(Math.random() * 500) + 50
  };
});

const rides = new Map();

function distanceKm(a, b) {
  const dx = (a.lat - b.lat) * 111;
  const dy = (a.lng - b.lng) * 85;
  return Math.sqrt(dx * dx + dy * dy);
}

function randomTripDistance() {
  return Number((3 + Math.random() * 35).toFixed(1));
}

function estimateFare(distance, categoryKey, serviceKey, waitMinutes = 0) {
  const services = serviceCatalog[categoryKey] || serviceCatalog.pickup_mini;
  const service = services[serviceKey] || Object.values(services)[0];
  const rateCard = categoryRateCard[categoryKey] || categoryRateCard.pickup_mini;

  const normalizedDistance = Math.max(0, Number(distance) || 0);
  const normalizedWait = Math.max(0, Number(waitMinutes) || 0);
  const demandFactor = 1 + Math.random() * 0.12;

  const subtotal =
    rateCard.startFare +
    normalizedDistance * rateCard.perKm +
    normalizedWait * rateCard.waitPerMin;

  const total = subtotal * (service.multiplier ?? 1) * demandFactor;
  return Number(total.toFixed(2));
}

function etaMinutes(driver, pickupPoint) {
  const km = distanceKm(driver, pickupPoint);
  return Math.max(3, Math.round((km / 0.4) * 2));
}

function serializeRide(ride) {
  return {
    id: ride.id,
    pickup: ride.pickup,
    dropoff: ride.dropoff,
    category: ride.category,
    service: ride.service,
    status: ride.status,
    requestedAt: ride.requestedAt,
    fareEstimate: ride.fareEstimate,
    tripDistanceKm: ride.tripDistanceKm,
    etaMin: ride.etaMin,
    driver: ride.driver,
    timeline: ride.timeline,
    progress: ride.progress
  };
}

function appendTimeline(ride, label) {
  ride.timeline.push({
    label,
    at: new Date().toISOString()
  });
}

function broadcastDrivers() {
  io.emit("drivers:update", drivers);
}

function broadcastRide(ride) {
  io.emit("ride:update", serializeRide(ride));
}

function findBestDriver(pickupPoint, category) {
  const availableInCategory = drivers.filter((d) => d.available && d.category === category);
  if (!availableInCategory.length) {
    return null;
  }

  return availableInCategory.sort((a, b) => {
    const distA = distanceKm(a, pickupPoint);
    const distB = distanceKm(b, pickupPoint);
    return distA - distB;
  })[0];
}

function progressRideLifecycle(ride) {
  const checkpoints = [
    { delay: 6000, status: "driver_arriving", progress: 0.18, label: "Tu conductor está en camino" },
    { delay: 15000, status: "in_progress", progress: 0.45, label: "Carga iniciada" },
    { delay: 26000, status: "in_progress", progress: 0.8, label: "Próximo a destino" },
    { delay: 38000, status: "completed", progress: 1, label: "Entrega completada" }
  ];

  checkpoints.forEach((step) => {
    setTimeout(() => {
      const current = rides.get(ride.id);
      if (!current || current.status === "cancelled") {
        return;
      }

      current.status = step.status;
      current.progress = step.progress;
      appendTimeline(current, step.label);

      if (step.status === "completed" && current.driver) {
        const driverObj = drivers.find((d) => d.id === current.driver.id);
        if (driverObj) {
          driverObj.available = true;
          driverObj.completedRides += 1;
        }
        current.etaMin = 0;
      }

      broadcastRide(current);
      broadcastDrivers();
    }, step.delay);
  });
}

// Endpoints API

app.get("/api/health", (_req, res) => {
  res.json({ ok: true, timestamp: new Date().toISOString() });
});

app.get("/api/categories", (_req, res) => {
  res.json(vehicleCategories);
});

app.get("/api/services/:category", (req, res) => {
  const services = serviceCatalog[req.params.category];
  if (!services) {
    return res.status(404).json({ error: "Categoría no encontrada" });
  }
  res.json(services);
});

app.get("/api/pricing", (_req, res) => {
  const pricing = Object.entries(categoryRateCard).map(([categoryKey, rates]) => ({
    category: categoryKey,
    categoryLabel: vehicleCategories[categoryKey]?.label || categoryKey,
    startFare: rates.startFare,
    perKmRate: rates.perKm,
    waitPerMinRate: rates.waitPerMin,
    currency: "MXN"
  }));
  res.json(pricing);
});

app.get("/api/quote", (req, res) => {
  const distance = Number(req.query.distance || randomTripDistance());
  const category = String(req.query.category || "pickup_mini");
  const service = String(req.query.service || "local");
  const waitMinutes = Number(req.query.waitMinutes || 0);

  const services = serviceCatalog[category];
  if (!services || !services[service]) {
    return res.status(400).json({ error: "Categoría o servicio inválido" });
  }

  const fareEstimate = estimateFare(distance, category, service, waitMinutes);
  const rateCard = categoryRateCard[category] || categoryRateCard.pickup_mini;

  return res.json({
    category,
    service,
    distance,
    waitMinutes,
    fareEstimate,
    startFare: rateCard.startFare,
    perKmRate: rateCard.perKm,
    waitPerMinRate: rateCard.waitPerMin,
    currency: "MXN"
  });
});

app.post("/api/rides", (req, res) => {
  const { pickup, dropoff, category, service, pickupPoint } = req.body || {};

  if (!pickup || !dropoff || !serviceCatalog[category] || !serviceCatalog[category][service]) {
    return res.status(400).json({
      error: "Debes enviar pickup, dropoff, categoría y servicio válidos"
    });
  }

  const ride = {
    id: uuidv4(),
    pickup,
    dropoff,
    category,
    service,
    requestedAt: new Date().toISOString(),
    status: "searching",
    tripDistanceKm: randomTripDistance(),
    fareEstimate: 0,
    etaMin: null,
    driver: null,
    timeline: [],
    progress: 0
  };

  ride.fareEstimate = estimateFare(ride.tripDistanceKm, ride.category, ride.service);
  appendTimeline(ride, "Buscando conductor en tu categoría");

  rides.set(ride.id, ride);
  broadcastRide(ride);

  setTimeout(() => {
    const current = rides.get(ride.id);
    if (!current || current.status !== "searching") {
      return;
    }

    const pickupGeo = pickupPoint || cityCenter;
    const selected = findBestDriver(pickupGeo, category);

    if (!selected) {
      current.status = "no_drivers";
      appendTimeline(current, "No hay conductores disponibles en esta categoría");
      broadcastRide(current);
      return;
    }

    selected.available = false;
    current.status = "accepted";
    current.progress = 0.07;
    current.driver = {
      id: selected.id,
      name: selected.name,
      rating: selected.rating,
      vehicle: selected.vehicle,
      completedRides: selected.completedRides
    };
    current.etaMin = etaMinutes(selected, pickupGeo);
    appendTimeline(current, `Conductor asignado: ${selected.name} en ${selected.vehicle.name}`);

    broadcastRide(current);
    broadcastDrivers();
    progressRideLifecycle(current);
  }, 3200);

  return res.status(201).json(serializeRide(ride));
});

app.get("/api/rides/:id", (req, res) => {
  const ride = rides.get(req.params.id);
  if (!ride) {
    return res.status(404).json({ error: "Solicitud de carga no encontrada" });
  }

  return res.json(serializeRide(ride));
});

app.post("/api/rides/:id/cancel", (req, res) => {
  const ride = rides.get(req.params.id);

  if (!ride) {
    return res.status(404).json({ error: "Solicitud de carga no encontrada" });
  }

  if (["completed", "cancelled"].includes(ride.status)) {
    return res.status(409).json({ error: "No se puede cancelar en este estado" });
  }

  ride.status = "cancelled";
  ride.progress = 0;
  appendTimeline(ride, "Solicitud cancelada");

  if (ride.driver) {
    const d = drivers.find((driver) => driver.id === ride.driver.id);
    if (d) {
      d.available = true;
    }
  }

  broadcastRide(ride);
  broadcastDrivers();

  return res.json(serializeRide(ride));
});

// Broadcast de conductores cada 2.5 segundos
setInterval(() => {
  drivers.forEach((d) => {
    const drift = d.available ? 0.0025 : 0.0008;
    d.lat += (Math.random() - 0.5) * drift;
    d.lng += (Math.random() - 0.5) * drift;
  });

  broadcastDrivers();
}, 2500);

io.on("connection", (socket) => {
  socket.emit("drivers:update", drivers);

  socket.on("ride:watch", (rideId) => {
    const ride = rides.get(rideId);
    if (ride) {
      socket.emit("ride:update", serializeRide(ride));
    }
  });
});

server.listen(PORT, () => {
  console.log(`KARRIT Platform running on http://localhost:${PORT}`);
  console.log(`\nCategorías disponibles:`);
  Object.values(vehicleCategories).forEach(cat => {
    console.log(`  - ${cat.label}: ${cat.capacity}`);
  });
});
