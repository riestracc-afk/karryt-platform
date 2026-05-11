const socket = typeof window.io === "function" ? window.io() : null;

const state = {
  currentRideId: null,
  currentRide: null,
  drivers: [],
  categories: {},
  selectedCategory: null
};

const elements = {
  categorySelect: document.getElementById("categorySelect"),
  serviceSelect: document.getElementById("serviceSelect"),
  rideForm: document.getElementById("rideForm"),
  pickupInput: document.getElementById("pickupInput"),
  dropoffInput: document.getElementById("dropoffInput"),
  quoteBtn: document.getElementById("quoteBtn"),
  requestBtn: document.getElementById("requestBtn"),
  cancelBtn: document.getElementById("cancelBtn"),
  fareEstimate: document.getElementById("fareEstimate"),
  mapSim: document.getElementById("mapSim"),
  availableDrivers: document.getElementById("availableDrivers"),
  driverInfo: document.getElementById("driverInfo"),
  timelineList: document.getElementById("timelineList"),
  rideIdMeta: document.getElementById("rideIdMeta"),
  rideStatusPill: document.getElementById("rideStatusPill"),
  tripProgressFill: document.getElementById("tripProgressFill"),
  progressPercent: document.getElementById("progressPercent"),
  pricingTableBody: document.getElementById("pricingTableBody")
};

const statusLabel = {
  searching: "Buscando conductor",
  accepted: "Conductor asignado",
  driver_arriving: "Conductor en camino",
  in_progress: "Carga en curso",
  completed: "Completado",
  cancelled: "Cancelado",
  no_drivers: "Sin conductores"
};

const dotMap = new Map();

function formatCurrency(n) {
  return new Intl.NumberFormat("es-ES", {
    style: "currency",
    currency: "MXN"
  }).format(Number(n || 0));
}

function randomDistance() {
  return Number((5 + Math.random() * 45).toFixed(1));
}

async function loadCategories() {
  try {
    const response = await fetch("/api/categories");
    state.categories = await response.json();
  } catch (error) {
    console.error("Error cargando categorías:", error);
    // Fallback: categorías hardcodeadas
    state.categories = {
      pickup_mini: {
        id: "pickup_mini",
        label: "Pick-up Mini",
        capacity: "Hasta 800 kg",
        description: "Vehículos compactos de carga ligera"
      },
      specialized_1t: {
        id: "specialized_1t",
        label: "Especializada 1.1T",
        capacity: "Hasta 1.1 tonelada",
        description: "Camionetas especializadas"
      },
      truck_3t: {
        id: "truck_3t",
        label: "Camión 3T",
        capacity: "Hasta 3 toneladas",
        description: "Camiones medianos"
      },
      dump_truck: {
        id: "dump_truck",
        label: "Camión de Volteo",
        capacity: "Caja 6m³",
        description: "Camiones para carga a granel"
      }
    };
  }

  elements.categorySelect.innerHTML = '<option value="">Selecciona una categoría...</option>';
  Object.entries(state.categories).forEach(([key, cat]) => {
    const option = document.createElement("option");
    option.value = key;
    option.textContent = `${cat.label} (${cat.capacity})`;
    elements.categorySelect.appendChild(option);
  });
}

async function loadServices(categoryKey) {
  try {
    const response = await fetch(`/api/services/${categoryKey}`);
    const services = await response.json();

    elements.serviceSelect.innerHTML = '<option value="">Selecciona un servicio...</option>';
    Object.entries(services).forEach(([key, svc]) => {
      const option = document.createElement("option");
      option.value = key;
      option.textContent = svc.label;
      elements.serviceSelect.appendChild(option);
    });
  } catch (error) {
    console.error("Error cargando servicios:", error);
    // Fallback: servicios por categoría
    const defaultServices = {
      pickup_mini: { local: { label: "Recorrido Local" }, regional: { label: "Recorrido Regional" } },
      specialized_1t: { fragile: { label: "Carga Frágil" }, structural: { label: "Carga Estructural" } },
      truck_3t: { standard: { label: "Carga Estándar" }, heavy: { label: "Carga Pesada" } },
      dump_truck: { bulk: { label: "Carga a Granel" }, specialized: { label: "Carga Especializada" } }
    };

    const services = defaultServices[categoryKey] || {};
    elements.serviceSelect.innerHTML = '<option value="">Selecciona un servicio...</option>';
    Object.entries(services).forEach(([key, svc]) => {
      const option = document.createElement("option");
      option.value = key;
      option.textContent = svc.label;
      elements.serviceSelect.appendChild(option);
    });
  }
}

async function recalculateQuote() {
  if (!state.selectedCategory || !elements.serviceSelect.value) {
    return;
  }

  const distance = randomDistance();
  const response = await fetch(
    `/api/quote?category=${state.selectedCategory}&service=${elements.serviceSelect.value}&distance=${distance}`
  );
  const data = await response.json();
  elements.fareEstimate.textContent = formatCurrency(data.fareEstimate);
}

async function loadPricing() {
  try {
    const response = await fetch("/api/pricing");
    const pricing = await response.json();

    if (!Array.isArray(pricing) || pricing.length === 0) {
      throw new Error("No pricing data");
    }

    elements.pricingTableBody.innerHTML = pricing
      .map((cat) => `
        <tr style="border-bottom: 1px solid #eee;">
          <td style="padding: 8px; font-weight: 500;">${cat.categoryLabel}</td>
          <td style="text-align: center; padding: 8px;">$${cat.startFare}</td>
          <td style="text-align: center; padding: 8px;">$${cat.perKmRate}</td>
          <td style="text-align: center; padding: 8px;">$${cat.waitPerMinRate}</td>
        </tr>
      `)
      .join("");
  } catch (error) {
    console.error("Error cargando tarifas:", error);
    // Fallback: mostrar tarifas hardcodeadas
    const defaultPricing = [
      { categoryLabel: "Pick-up Mini", startFare: 150, perKmRate: 18, waitPerMinRate: 4 },
      { categoryLabel: "Especializada 1.1T", startFare: 300, perKmRate: 30, waitPerMinRate: 6 },
      { categoryLabel: "Camión 3T", startFare: 700, perKmRate: 45, waitPerMinRate: 8 },
      { categoryLabel: "Camión de Volteo", startFare: 1500, perKmRate: 75, waitPerMinRate: 12 }
    ];

    elements.pricingTableBody.innerHTML = defaultPricing
      .map((cat) => `
        <tr style="border-bottom: 1px solid #eee;">
          <td style="padding: 8px; font-weight: 500;">${cat.categoryLabel}</td>
          <td style="text-align: center; padding: 8px;">$${cat.startFare}</td>
          <td style="text-align: center; padding: 8px;">$${cat.perKmRate}</td>
          <td style="text-align: center; padding: 8px;">$${cat.waitPerMinRate}</td>
        </tr>
      `)
      .join("");
  }
}

function updateRideUI() {
  const ride = state.currentRide;

  if (!ride) {
    elements.rideIdMeta.textContent = "ID: --";
    elements.rideStatusPill.textContent = "Sin carga activa";
    elements.driverInfo.textContent = "Esperando asignación de conductor...";
    elements.cancelBtn.disabled = true;
    elements.tripProgressFill.style.width = "0%";
    elements.progressPercent.textContent = "0%";
    return;
  }

  elements.rideIdMeta.textContent = `ID: ${ride.id.slice(0, 8)}...`;
  elements.rideStatusPill.textContent = statusLabel[ride.status] || ride.status;

  const progress = Math.round((ride.progress || 0) * 100);
  elements.tripProgressFill.style.width = `${progress}%`;
  elements.progressPercent.textContent = `${progress}%`;

  const canCancel = !["cancelled", "completed", "no_drivers"].includes(ride.status);
  elements.cancelBtn.disabled = !canCancel;

  if (ride.driver) {
    elements.driverInfo.textContent = `${ride.driver.name} · ${ride.driver.vehicle.name} · ⭐${ride.driver.rating} · ${ride.driver.completedRides} entregas · ETA ${ride.etaMin || 0} min`;
  } else if (ride.status === "no_drivers") {
    elements.driverInfo.textContent = "No hay conductores disponibles en esta categoría. Intenta nuevamente en unos minutos.";
  } else {
    elements.driverInfo.textContent = "Buscando el mejor conductor especializado...";
  }

  if (Array.isArray(ride.timeline) && ride.timeline.length) {
    elements.timelineList.innerHTML = ride.timeline
      .slice()
      .reverse()
      .map((event) => {
        const date = new Date(event.at);
        return `<li>${event.label} · ${date.toLocaleTimeString("es-ES")}</li>`;
      })
      .join("");
  }
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function renderDrivers(drivers) {
  state.drivers = drivers;
  const available = drivers.filter((d) => d.available).length;
  elements.availableDrivers.textContent = `${available} conductores libres`;

  const existingIds = new Set(drivers.map((d) => d.id));

  dotMap.forEach((dot, id) => {
    if (!existingIds.has(id)) {
      dot.remove();
      dotMap.delete(id);
    }
  });

  drivers.forEach((driver) => {
    let dot = dotMap.get(driver.id);

    if (!dot) {
      dot = document.createElement("div");
      dot.className = "driver-dot";
      dot.title = `${driver.name} (${driver.category})`;
      elements.mapSim.appendChild(dot);
      dotMap.set(driver.id, dot);
    }

    dot.classList.toggle("busy", !driver.available);

    const x = clamp(((driver.lng + 3.73) * 10000) % 100, 5, 95);
    const y = clamp(((driver.lat - 40.38) * 2200) % 100, 5, 95);

    dot.style.left = `${x}%`;
    dot.style.top = `${y}%`;
  });
}

if (socket) {
  socket.on("drivers:update", (drivers) => {
    renderDrivers(drivers);
  });

  socket.on("ride:update", (ride) => {
    if (state.currentRideId && ride.id !== state.currentRideId) {
      return;
    }

    state.currentRide = ride;
    updateRideUI();
  });
}

async function createRide(event) {
  event.preventDefault();

  if (state.currentRideId && state.currentRide && !["completed", "cancelled", "no_drivers"].includes(state.currentRide.status)) {
    return;
  }

  if (!state.selectedCategory || !elements.serviceSelect.value) {
    alert("Por favor selecciona categoría y servicio");
    return;
  }

  const payload = {
    pickup: elements.pickupInput.value.trim(),
    dropoff: elements.dropoffInput.value.trim(),
    category: state.selectedCategory,
    service: elements.serviceSelect.value,
    pickupPoint: { lat: 40.4168, lng: -3.7038 }
  };

  if (!payload.pickup || !payload.dropoff) {
    return;
  }

  elements.requestBtn.disabled = true;

  try {
    const response = await fetch("/api/rides", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });

    if (!response.ok) {
      throw new Error("No se pudo crear la solicitud de carga");
    }

    const ride = await response.json();
    state.currentRideId = ride.id;
    state.currentRide = ride;
    if (socket) {
      socket.emit("ride:watch", ride.id);
    }
    updateRideUI();
  } catch (error) {
    alert("Error solicitando carga. Intenta nuevamente.");
  } finally {
    elements.requestBtn.disabled = false;
  }
}

async function cancelRide() {
  if (!state.currentRideId) {
    return;
  }

  const response = await fetch(`/api/rides/${state.currentRideId}/cancel`, { method: "POST" });
  if (!response.ok) {
    alert("No se pudo cancelar la carga");
    return;
  }

  const ride = await response.json();
  state.currentRide = ride;
  updateRideUI();
}

async function init() {
  await loadCategories();
  await loadPricing();

  elements.categorySelect.addEventListener("change", async (e) => {
    state.selectedCategory = e.target.value;
    if (state.selectedCategory) {
      await loadServices(state.selectedCategory);
      elements.serviceSelect.disabled = false;
    } else {
      elements.serviceSelect.innerHTML = '<option value="">Primero selecciona una categoría</option>';
      elements.serviceSelect.disabled = true;
    }
    elements.fareEstimate.textContent = "MXN --.--";
  });

  elements.rideForm.addEventListener("submit", createRide);
  elements.cancelBtn.addEventListener("click", cancelRide);
  elements.quoteBtn.addEventListener("click", recalculateQuote);
  elements.serviceSelect.addEventListener("change", recalculateQuote);

  elements.categorySelect.disabled = false;
  elements.serviceSelect.disabled = true;
}

init();
