const express = require("express");
const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const dotenv = require("dotenv");
const { Server } = require("socket.io");
const { v4: uuidv4 } = require("uuid");
const { admin: firebaseAdmin } = require("./config/firebase");

dotenv.config();
dotenv.config({ path: path.join(__dirname, "flutter_app", ".env") });

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

const PORT = process.env.PORT || 3000;
const NODE_ENV = String(process.env.NODE_ENV || "development").toLowerCase();
const AUTH_ENFORCE_ROLES = parseBooleanEnv(process.env.AUTH_ENFORCE_ROLES, NODE_ENV === "production");
const AUTH_ALLOW_DEV_HEADERS = parseBooleanEnv(process.env.AUTH_ALLOW_DEV_HEADERS, NODE_ENV !== "production");
const AUTH_DEV_SHARED_KEY = String(process.env.AUTH_DEV_SHARED_KEY || "").trim();
const DEFAULT_SCHEDULED_VISIBILITY_WINDOW_HOURS = Number.isFinite(Number(process.env.SCHEDULED_VISIBILITY_WINDOW_HOURS))
  ? Math.max(1, Number(process.env.SCHEDULED_VISIBILITY_WINDOW_HOURS))
  : 24;
const DEFAULT_DRIVER_COMMISSION_RATE = Number.isFinite(Number(process.env.DRIVER_COMMISSION_RATE))
  ? Math.max(0, Math.min(0.95, Number(process.env.DRIVER_COMMISSION_RATE)))
  : 0.18;
const DEFAULT_MANEUVER_LOADER_PAY_PER_TRIP = 250;
const DEFAULT_MANEUVER_PLATFORM_MARGIN_RATE = Number.isFinite(Number(process.env.MANEUVER_PLATFORM_MARGIN_RATE))
  ? Math.max(0, Number(process.env.MANEUVER_PLATFORM_MARGIN_RATE))
  : 0.2;
const DEFAULT_MANEUVER_MAX_DISTANCE_METERS = 4;
const DRIVER_OFFER_PENDING_DELAY_MS = Number.isFinite(Number(process.env.DRIVER_OFFER_PENDING_DELAY_MS))
  ? Math.max(15000, Number(process.env.DRIVER_OFFER_PENDING_DELAY_MS))
  : 45000;
const PENDING_RIDE_RETRY_INTERVAL_MS = Number.isFinite(Number(process.env.PENDING_RIDE_RETRY_INTERVAL_MS))
  ? Math.max(15000, Number(process.env.PENDING_RIDE_RETRY_INTERVAL_MS))
  : 30000;
const DATA_DIR = path.join(__dirname, "data");
const FAVORITES_FILE = path.join(DATA_DIR, "address-favorites.json");
const RECENTS_FILE = path.join(DATA_DIR, "address-recents.json");
const ADMIN_PRICING_FILE = path.join(DATA_DIR, "admin-pricing-config.json");
const ADMIN_VEHICLES_FILE = path.join(DATA_DIR, "admin-vehicles.json");
const ADMIN_DRIVERS_FILE = path.join(DATA_DIR, "admin-drivers.json");
const ADMIN_DRIVER_AUDIT_FILE = path.join(DATA_DIR, "admin-driver-audit.json");
const ADMIN_CATALOGS_FILE = path.join(DATA_DIR, "admin-catalogs.json");
const DRIVER_RATINGS_FILE = path.join(DATA_DIR, "driver-ratings.json");
const ADMIN_CUSTOMERS_FILE = path.join(DATA_DIR, "admin-customers.json");
const CUSTOMER_RATINGS_FILE = path.join(DATA_DIR, "customer-ratings.json");
const ADMIN_INCIDENTS_FILE = path.join(DATA_DIR, "admin-incidents.json");
const ADMIN_SANCTIONS_FILE = path.join(DATA_DIR, "admin-sanctions.json");
const DRIVER_LEDGER_FILE = path.join(DATA_DIR, "driver-ledger.json");
const DRIVER_NOTIFICATION_DEVICES_FILE = path.join(DATA_DIR, "driver-notification-devices.json");
const FLUTTER_WEB_DIR = path.join(__dirname, "flutter_app", "build", "hosting");
const FLUTTER_WEB_INDEX = path.join(FLUTTER_WEB_DIR, "index.html");
const FLUTTER_WEB_CHOFER_INDEX = path.join(FLUTTER_WEB_DIR, "chofer", "index.html");
const FLUTTER_WEB_ADMIN_INDEX = path.join(FLUTTER_WEB_DIR, "admin", "index.html");
const hasFlutterWebBuild = fs.existsSync(FLUTTER_WEB_INDEX);
const GOOGLE_PLACES_API_KEY = process.env.GOOGLE_PLACES_API_KEY || "";
const GOOGLE_ADDRESS_VALIDATION_API_KEY = process.env.GOOGLE_ADDRESS_VALIDATION_API_KEY || GOOGLE_PLACES_API_KEY;
const NOMINATIM_USER_AGENT =
  process.env.NOMINATIM_USER_AGENT ||
  "Karryt Platform/1.0 (contact: soporte@karryt.local)";
const DRIVER_PIN_PEPPER = String(process.env.DRIVER_PIN_PEPPER || "karryt-driver-pin-v1");

function normalizePhoneDigits(value) {
  return String(value || "").replace(/\D/g, "").trim();
}

function normalizeLicenseNumber(value) {
  return String(value || "").trim().toUpperCase();
}

function isValidDriverPin(value) {
  return /^\d{4}$/.test(String(value || "").trim());
}

function hashDriverPin(pin) {
  const normalized = String(pin || "").trim();
  return crypto
    .createHash("sha256")
    .update(`${DRIVER_PIN_PEPPER}:${normalized}`)
    .digest("hex");
}

app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Karryt-Role, X-Karryt-User-Id, X-Karryt-Auth-Key");

  if (req.method === "OPTIONS") {
    return res.sendStatus(204);
  }

  next();
});

app.use(express.json());
if (hasFlutterWebBuild) {
  app.use(express.static(FLUTTER_WEB_DIR));
}
app.use("/logo", express.static(path.join(__dirname, "logo")));

app.get("/api/health", (_req, res) => {
  res.json({
    ok: true,
    service: "karryt-api",
    storageMode: String(process.env.USE_FIRESTORE).toLowerCase() === "true" ? "firestore" : "memory",
    frontendBuild: hasFlutterWebBuild,
    timestamp: new Date().toISOString()
  });
});

function parseBooleanEnv(value, defaultValue = false) {
  if (value === undefined || value === null || String(value).trim() === "") {
    return defaultValue;
  }

  const normalized = String(value).trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }
  return defaultValue;
}

function normalizeAuthRole(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (normalized === "admin") {
    return "admin";
  }
  if (["driver", "chofer"].includes(normalized)) {
    return "driver";
  }
  if (["customer", "user", "usuario", "rider"].includes(normalized)) {
    return "customer";
  }
  return "guest";
}

function extractBearerToken(req) {
  const authHeader = String(req.headers.authorization || "");
  if (!authHeader) {
    return "";
  }

  const [scheme, token] = authHeader.split(" ");
  if (!scheme || !token || scheme.toLowerCase() !== "bearer") {
    return "";
  }

  return token.trim();
}

function resolveRoleFromClaims(decodedToken) {
  if (!decodedToken || typeof decodedToken !== "object") {
    return "guest";
  }

  const roleCandidates = [];
  if (decodedToken.role) {
    roleCandidates.push(decodedToken.role);
  }
  if (decodedToken.karrytRole) {
    roleCandidates.push(decodedToken.karrytRole);
  }
  if (Array.isArray(decodedToken.roles)) {
    roleCandidates.push(...decodedToken.roles);
  }
  if (decodedToken.admin === true) {
    roleCandidates.push("admin");
  }

  for (const candidate of roleCandidates) {
    const normalized = normalizeAuthRole(candidate);
    if (normalized !== "guest") {
      return normalized;
    }
  }

  return "customer";
}

function hasFirebaseAuthReady() {
  return Boolean(firebaseAdmin && Array.isArray(firebaseAdmin.apps) && firebaseAdmin.apps.length > 0 && typeof firebaseAdmin.auth === "function");
}

function getAuthContext(req) {
  if (!req.auth || typeof req.auth !== "object") {
    return {
      authenticated: false,
      role: "guest",
      userId: "",
      provider: null,
      claims: {}
    };
  }
  return req.auth;
}

function isAdminAuth(req) {
  const auth = getAuthContext(req);
  return auth.authenticated === true && auth.role === "admin";
}

function enforceSelfOrAdmin(req, res, { role, actorId, actorLabel }) {
  if (!AUTH_ENFORCE_ROLES) {
    return true;
  }

  if (isAdminAuth(req)) {
    return true;
  }

  const auth = getAuthContext(req);
  if (!auth.authenticated) {
    res.status(401).json({ error: "Autenticacion requerida" });
    return false;
  }

  if (auth.role !== role) {
    res.status(403).json({ error: `Permisos insuficientes para ${actorLabel}` });
    return false;
  }

  const normalizedActorId = String(actorId || "").trim();
  if (!normalizedActorId || String(auth.userId || "").trim() !== normalizedActorId) {
    res.status(403).json({ error: `Solo puedes operar como ${actorLabel} autenticado` });
    return false;
  }

  return true;
}

async function authenticateRequest(req, _res, next) {
  req.auth = {
    authenticated: false,
    role: "guest",
    userId: "",
    provider: null,
    claims: {}
  };

  const bearerToken = extractBearerToken(req);
  if (bearerToken && hasFirebaseAuthReady()) {
    try {
      const decoded = await firebaseAdmin.auth().verifyIdToken(bearerToken);
      req.auth = {
        authenticated: true,
        role: resolveRoleFromClaims(decoded),
        userId: String(decoded.karrytUserId || decoded.uid || "").trim(),
        uid: String(decoded.uid || "").trim(),
        provider: "firebase",
        claims: decoded
      };
    } catch (_error) {
      req.auth = {
        authenticated: false,
        role: "guest",
        userId: "",
        provider: null,
        claims: {}
      };
    }
  }

  if (!req.auth.authenticated && AUTH_ALLOW_DEV_HEADERS) {
    const role = normalizeAuthRole(req.headers["x-karryt-role"]);
    const userId = String(req.headers["x-karryt-user-id"] || "").trim();
    if (role !== "guest" && userId) {
      const providedKey = String(req.headers["x-karryt-auth-key"] || "").trim();
      if (!AUTH_DEV_SHARED_KEY || AUTH_DEV_SHARED_KEY === providedKey) {
        req.auth = {
          authenticated: true,
          role,
          userId,
          uid: userId,
          provider: "dev-header",
          claims: {}
        };
      }
    }
  }

  next();
}

function requireAnyRole(...roles) {
  const allowed = new Set(roles.map((role) => normalizeAuthRole(role)).filter((role) => role !== "guest"));
  return (req, res, next) => {
    if (!AUTH_ENFORCE_ROLES) {
      return next();
    }

    const auth = getAuthContext(req);
    if (!auth.authenticated) {
      return res.status(401).json({ error: "Autenticacion requerida" });
    }

    if (!allowed.has(auth.role)) {
      return res.status(403).json({ error: "Permisos insuficientes" });
    }

    return next();
  };
}

app.use(authenticateRequest);

function ensureDataDir() {
  if (!fs.existsSync(DATA_DIR)) {
    fs.mkdirSync(DATA_DIR, { recursive: true });
  }
}

function normalizeAddressLookupText(value) {
  return String(value || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function buildAddressSearchQueries(value) {
  const query = String(value || "").replace(/\s+/g, " ").trim();
  if (!query) {
    return [];
  }

  const variants = [];
  const addVariant = (candidate) => {
    const normalized = String(candidate || "").replace(/\s+/g, " ").trim();
    if (!normalized || variants.includes(normalized)) {
      return;
    }
    variants.push(normalized);
  };

  addVariant(query);
  const withoutColonyTerms = query
    .replace(/\bcolonia\b/gi, "")
    .replace(/\bfraccionamiento\b/gi, "")
    .replace(/\bfracc\.?\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();

  if (withoutColonyTerms && withoutColonyTerms !== query) {
    addVariant(withoutColonyTerms);
  }

  const municipalityPattern = new RegExp(`\\b(${tripRules.municipalities.join("|")})\\b`, "i");
  const colonyMarkerPattern = /\b(colonia|fraccionamiento|fracc\.?)\b/i;
  const colonyMarkerMatch = query.match(colonyMarkerPattern);
  const municipalityMatch = query.match(municipalityPattern);

  if (colonyMarkerMatch && municipalityMatch) {
    const colonyIndex = query.search(colonyMarkerPattern);
    const municipalityIndex = query.search(municipalityPattern);

    if (colonyIndex >= 0 && municipalityIndex > colonyIndex) {
      const head = query.slice(0, colonyIndex).trim();
      const colonyText = query
        .slice(colonyIndex + colonyMarkerMatch[0].length, municipalityIndex)
        .trim();
      const tail = query.slice(municipalityIndex).trim();

      if (head && tail) {
        addVariant(`${head} ${tail}`);
        addVariant(`${head}, ${tail}`);
      }

      if (colonyText) {
        const colonyTokens = colonyText.split(/\s+/).filter(Boolean);
        if (colonyTokens.length >= 1) {
          addVariant(`${head} ${colonyTokens.slice(-1).join(" ")} ${tail}`);
        }
        if (colonyTokens.length >= 2) {
          addVariant(`${head} ${colonyTokens.slice(-2).join(" ")} ${tail}`);
        }
      }
    }
  }

  const streetNumberMatch = query.match(/^(avenida|av|calle|c|camino|carrera)\s+(.+?)\s+(\d+[a-z]?)(.*)$/i);
  if (streetNumberMatch) {
    const [, streetType, streetName, streetNumber, tail] = streetNumberMatch;
    addVariant(
      `${streetNumber} ${streetType} ${streetName}${tail}`
        .replace(/\s+/g, " ")
        .trim()
    );
    addVariant(
      `${streetType} ${streetName}, ${streetNumber}${tail}`
        .replace(/\s+/g, " ")
        .trim()
    );
    addVariant(
      `${streetType} ${streetName} ${streetNumber}, ${tail}`
        .replace(/\s+,/g, ",")
        .replace(/,+/g, ",")
        .replace(/\s+/g, " ")
        .trim()
    );
  }

  const genericNumberMatch = query.match(/^(.+?)\s+(\d+[a-z]?)(.*)$/i);
  if (genericNumberMatch) {
    const [, head, streetNumber, tail] = genericNumberMatch;
    addVariant(`${streetNumber} ${head}${tail}`.replace(/\s+/g, " ").trim());
  }

  return variants.slice(0, 8);
}

function buildGoogleSuggestion(item) {
  const raw = item && typeof item === "object" ? item : {};
  const placeId = typeof raw.place_id === "string" ? raw.place_id.trim() : "";
  if (!placeId) {
    return null;
  }

  const formatting = raw.structured_formatting && typeof raw.structured_formatting === "object"
    ? raw.structured_formatting
    : {};
  const primaryText = typeof formatting.main_text === "string" ? formatting.main_text.trim() : "";
  const secondaryText = typeof formatting.secondary_text === "string" ? formatting.secondary_text.trim() : "";
  const description = typeof raw.description === "string" ? raw.description.trim() : "";
  const displayName = secondaryText
    ? `${primaryText || description}, ${secondaryText}`
    : (primaryText || description || "Direccion");

  return {
    display_name: displayName,
    lat: "0",
    lon: "0",
    place_id: placeId,
    primary_text: primaryText || null,
    secondary_text: secondaryText || null,
    provider: "google"
  };
}

function buildSuggestionKey(item) {
  const displayName = normalizeAddressLookupText(item.display_name || item.displayName || "");
  const placeId = String(item.place_id || item.placeId || "").trim();
  const lat = Number(item.lat);
  const lon = Number(item.lon ?? item.lng);
  if (placeId) {
    return `google:${placeId}`;
  }
  if (Number.isFinite(lat) && Number.isFinite(lon)) {
    return `${displayName}|${lat.toFixed(5)}|${lon.toFixed(5)}`;
  }
  return displayName;
}

function dedupeAddressSuggestions(items) {
  const seen = new Set();
  const deduped = [];

  for (const item of items) {
    const key = buildSuggestionKey(item);
    if (!key || seen.has(key)) {
      continue;
    }
    seen.add(key);
    deduped.push(item);
  }

  return deduped;
}

const ADDRESS_QUERY_STOP_WORDS = new Set([
  "a",
  "al",
  "av",
  "avenida",
  "calle",
  "camino",
  "carrera",
  "col",
  "colonia",
  "de",
  "del",
  "el",
  "en",
  "estado",
  "fracc",
  "fraccionamiento",
  "jalisco",
  "la",
  "los",
  "mexico",
  "municipio",
  "pais",
  "region",
]);

function extractMeaningfulAddressTokens(value) {
  return normalizeAddressLookupText(value)
    .split(" ")
    .filter((token) => {
      if (!token || ADDRESS_QUERY_STOP_WORDS.has(token)) {
        return false;
      }
      if (/^\d+[a-z]?$/.test(token)) {
        return false;
      }
      return token.length >= 2;
    });
}

function rankAddressSuggestionsByQuery(query, items) {
  const normalizedQuery = normalizeAddressLookupText(query);
  const queryTokens = extractMeaningfulAddressTokens(query);

  return [...items].sort((left, right) => {
    const scoreSuggestion = (item) => {
      const text = normalizeAddressLookupText(item.display_name || item.displayName || "");
      let score = 0;

      if (normalizedQuery && text === normalizedQuery) {
        score += 240;
      } else if (normalizedQuery && text.startsWith(normalizedQuery)) {
        score += 140;
      } else if (normalizedQuery && text.includes(normalizedQuery)) {
        score += 80;
      }

      let tokenMatches = 0;
      for (const token of queryTokens) {
        if (text.includes(token)) {
          tokenMatches += 1;
          score += token.length >= 6 ? 30 : 18;
        }
      }

      return { score, tokenMatches, textLength: text.length };
    };

    const leftScore = scoreSuggestion(left);
    const rightScore = scoreSuggestion(right);

    if (rightScore.score !== leftScore.score) {
      return rightScore.score - leftScore.score;
    }
    if (rightScore.tokenMatches !== leftScore.tokenMatches) {
      return rightScore.tokenMatches - leftScore.tokenMatches;
    }
    return leftScore.textLength - rightScore.textLength;
  });
}

async function fetchJson(url, options) {
  const response = await fetch(url, options);
  const data = await response.json().catch(() => null);
  return { response, data };
}

async function fetchGoogleAutocompleteSuggestions(query, { biasLat, biasLng } = {}) {
  if (!GOOGLE_PLACES_API_KEY) {
    return [];
  }

  const requestOnce = async (restrictToAddress) => {
    const params = new URLSearchParams({
      input: query,
      key: GOOGLE_PLACES_API_KEY,
      language: "es",
      components: "country:mx"
    });

    if (restrictToAddress) {
      params.set("types", "address");
    }

    if (Number.isFinite(biasLat) && Number.isFinite(biasLng)) {
      params.set("location", `${biasLat},${biasLng}`);
      params.set("radius", "40000");
    }

    const { data } = await fetchJson(
      `https://maps.googleapis.com/maps/api/place/autocomplete/json?${params.toString()}`
    );

    if (!data || typeof data !== "object") {
      return [];
    }

    const predictions = Array.isArray(data.predictions) ? data.predictions : [];
    return predictions.map(buildGoogleSuggestion).filter(Boolean);
  };

  const addressResults = await requestOnce(true);
  if (addressResults.length > 0) {
    return addressResults;
  }

  return requestOnce(false);
}

async function fetchGooglePlaceDetails(placeId, meta = {}) {
  if (!GOOGLE_PLACES_API_KEY) {
    return null;
  }

  const params = new URLSearchParams({
    place_id: placeId,
    key: GOOGLE_PLACES_API_KEY,
    fields: "geometry"
  });

  const { data } = await fetchJson(
    `https://maps.googleapis.com/maps/api/place/details/json?${params.toString()}`
  );

  if (!data || typeof data !== "object" || typeof data.result !== "object") {
    return null;
  }

  const geometry = data.result.geometry;
  const location = geometry && typeof geometry === "object" ? geometry.location : null;
  const lat = location && typeof location.lat === "number" ? location.lat : null;
  const lon = location && typeof location.lng === "number" ? location.lng : null;
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    return null;
  }

  const primaryText = typeof meta.primaryText === "string" ? meta.primaryText.trim() : "";
  const secondaryText = typeof meta.secondaryText === "string" ? meta.secondaryText.trim() : "";
  const displayName = typeof meta.displayName === "string" && meta.displayName.trim().length > 0
    ? meta.displayName.trim()
    : (secondaryText ? `${primaryText}, ${secondaryText}` : primaryText || "Direccion");

  return {
    display_name: displayName,
    lat: String(lat),
    lon: String(lon),
    place_id: placeId,
    primary_text: primaryText || null,
    secondary_text: secondaryText || null,
    provider: "google"
  };
}

function getValidationComponent(components, componentType) {
  if (!Array.isArray(components)) {
    return null;
  }

  return components.find((component) => {
    if (!component || typeof component !== "object") {
      return false;
    }

    return component.componentType === componentType;
  }) || null;
}

function parseValidatedAddressSuggestion(result, fallbackDisplayName) {
  if (!result || typeof result !== "object") {
    return null;
  }

  const verdict = result.verdict && typeof result.verdict === "object" ? result.verdict : {};
  const address = result.address && typeof result.address === "object" ? result.address : {};
  const geocode = result.geocode && typeof result.geocode === "object" ? result.geocode : {};

  const addressComponents = Array.isArray(address.addressComponents)
    ? address.addressComponents
    : [];
  const streetNumberComponent = getValidationComponent(addressComponents, "street_number");
  const routeComponent = getValidationComponent(addressComponents, "route");

  const streetNumberConfirmed = streetNumberComponent
    && streetNumberComponent.confirmationLevel === "CONFIRMED";
  const routeConfirmed = routeComponent
    ? routeComponent.confirmationLevel === "CONFIRMED"
    : true;
  const validationGranularity = String(verdict.validationGranularity || "");
  const addressComplete = verdict.addressComplete === true;
  const possibleNextAction = String(verdict.possibleNextAction || "");
  const exactGranularity = validationGranularity === "PREMISE" || validationGranularity === "SUB_PREMISE";
  const exactEnough = (streetNumberConfirmed && routeConfirmed && exactGranularity)
    || (streetNumberConfirmed && addressComplete && possibleNextAction === "ACCEPT");

  if (!exactEnough) {
    return null;
  }

  const location = geocode.location && typeof geocode.location === "object"
    ? geocode.location
    : null;
  const lat = location && Number.isFinite(Number(location.latitude))
    ? Number(location.latitude)
    : null;
  const lng = location && Number.isFinite(Number(location.longitude))
    ? Number(location.longitude)
    : null;

  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return null;
  }

  const formattedAddress = typeof address.formattedAddress === "string"
    ? address.formattedAddress.trim()
    : "";
  const displayName = formattedAddress || fallbackDisplayName || "Direccion";
  const postalAddress = address.postalAddress && typeof address.postalAddress === "object"
    ? address.postalAddress
    : {};

  const primaryText = typeof postalAddress.addressLines?.[0] === "string"
    ? postalAddress.addressLines[0].trim()
    : null;
  const secondaryParts = [];
  if (typeof postalAddress.locality === "string" && postalAddress.locality.trim()) {
    secondaryParts.push(postalAddress.locality.trim());
  }
  if (typeof postalAddress.administrativeArea === "string" && postalAddress.administrativeArea.trim()) {
    secondaryParts.push(postalAddress.administrativeArea.trim());
  }
  if (typeof postalAddress.postalCode === "string" && postalAddress.postalCode.trim()) {
    secondaryParts.push(postalAddress.postalCode.trim());
  }

  return {
    display_name: displayName,
    lat: String(lat),
    lon: String(lng),
    primary_text: primaryText,
    secondary_text: secondaryParts.length > 0 ? secondaryParts.join(", ") : null,
    provider: "google_validation",
    validation_granularity: validationGranularity,
    address_complete: addressComplete,
    possible_next_action: possibleNextAction,
    street_number_confirmed: streetNumberConfirmed,
    route_confirmed: routeConfirmed,
    response_id: typeof result.responseId === "string" ? result.responseId : undefined
  };
}

async function fetchGoogleValidatedAddressSuggestion(query) {
  if (!GOOGLE_ADDRESS_VALIDATION_API_KEY) {
    return null;
  }

  const variants = buildAddressSearchQueries(query).slice(0, 2);
  const candidateQueries = variants.length > 0 ? variants : [query];

  for (const candidate of candidateQueries) {
    try {
      const response = await fetch(
        `https://addressvalidation.googleapis.com/v1:validateAddress?key=${GOOGLE_ADDRESS_VALIDATION_API_KEY}`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json"
          },
          body: JSON.stringify({
            address: {
              regionCode: "MX",
              addressLines: [candidate]
            }
          })
        }
      );

      if (!response.ok) {
        continue;
      }

      const data = await response.json().catch(() => null);
      const result = data && typeof data === "object" ? data.result : null;
      const suggestion = parseValidatedAddressSuggestion(result, candidate);
      if (suggestion) {
        return suggestion;
      }
    } catch (error) {
      console.warn("Address validation fallback:", error.message);
    }
  }

  return null;
}

function shouldRunAddressValidation(query) {
  if (typeof query !== "string") {
    return false;
  }

  const normalized = query.trim();
  if (normalized.length < 12) {
    return false;
  }

  // Require a visible street number and at least one separator token
  // so we avoid expensive validation on short, partial autocomplete text.
  const hasStreetNumber = /\b\d{1,5}[A-Za-z]?\b/.test(normalized);
  const hasAddressStructure = /\s|,/.test(normalized);
  return hasStreetNumber && hasAddressStructure;
}

async function fetchNominatimSuggestions(query, { biasLat, biasLng } = {}) {
  const collected = [];

  for (const variant of buildAddressSearchQueries(query)) {
    const params = new URLSearchParams({
      q: variant,
      format: "jsonv2",
      "accept-language": "es",
      addressdetails: "1",
      limit: "8",
      countrycodes: "mx",
      dedupe: "1"
    });

    if (Number.isFinite(biasLat) && Number.isFinite(biasLng)) {
      const latDelta = 0.22;
      const lngDelta = latDelta / Math.max(0.3, Math.abs(Math.cos((biasLat * Math.PI) / 180)));
      params.set(
        "viewbox",
        `${(biasLng - lngDelta).toFixed(4)},${(biasLat + latDelta).toFixed(4)},${(biasLng + lngDelta).toFixed(4)},${(biasLat - latDelta).toFixed(4)}`
      );
    }

    const { response, data } = await fetchJson(
      `https://nominatim.openstreetmap.org/search?${params.toString()}`,
      {
        headers: {
          "User-Agent": NOMINATIM_USER_AGENT,
          "Accept-Language": "es"
        }
      }
    );

    if (!response.ok || !Array.isArray(data)) {
      continue;
    }

    collected.push(
      ...data.map((item) => ({
        display_name: typeof item.display_name === "string" ? item.display_name.trim() : "Direccion",
        lat: String(item.lat ?? "0"),
        lon: String(item.lon ?? "0"),
        provider: "nominatim"
      }))
    );

    if (dedupeAddressSuggestions(collected).length >= 8) {
      break;
    }
  }

  return dedupeAddressSuggestions(collected).slice(0, 8);
}

async function reverseGeocodeGoogle(lat, lng) {
  if (!GOOGLE_PLACES_API_KEY) {
    return null;
  }

  const params = new URLSearchParams({
    latlng: `${lat},${lng}`,
    key: GOOGLE_PLACES_API_KEY,
    language: "es"
  });
  const { data } = await fetchJson(
    `https://maps.googleapis.com/maps/api/geocode/json?${params.toString()}`
  );

  if (!data || typeof data !== "object" || !Array.isArray(data.results) || data.results.length === 0) {
    return null;
  }

  const formatted = data.results[0] && typeof data.results[0].formatted_address === "string"
    ? data.results[0].formatted_address.trim()
    : "";
  return formatted || null;
}

async function reverseGeocodeNominatim(lat, lng) {
  const params = new URLSearchParams({
    lat: String(lat),
    lon: String(lng),
    format: "jsonv2",
    "accept-language": "es",
    zoom: "18"
  });
  const { response, data } = await fetchJson(
    `https://nominatim.openstreetmap.org/reverse?${params.toString()}`,
    {
      headers: {
        "User-Agent": NOMINATIM_USER_AGENT,
        "Accept-Language": "es"
      }
    }
  );

  if (!response.ok || !data || typeof data !== "object") {
    return null;
  }

  const displayName = typeof data.display_name === "string" ? data.display_name.trim() : "";
  return displayName || null;
}

function normalizeAddressFavorite(item) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const displayName = String(item.displayName || item.display_name || item.name || "").trim();
  const lat = Number(item.lat);
  const lng = Number(item.lng ?? item.lon);

  if (!displayName || !Number.isFinite(lat) || !Number.isFinite(lng)) {
    return null;
  }

  return {
    displayName,
    lat: Number(lat.toFixed(6)),
    lng: Number(lng.toFixed(6))
  };
}

function loadFavoriteAddresses() {
  ensureDataDir();

  try {
    if (!fs.existsSync(FAVORITES_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(FAVORITES_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed.map(normalizeAddressFavorite).filter(Boolean);
  } catch (error) {
    console.warn("No se pudieron cargar favoritos de direcciones:", error.message);
    return [];
  }
}

function saveFavoriteAddresses(addresses) {
  ensureDataDir();
  const normalized = Array.isArray(addresses) ? addresses.map(normalizeAddressFavorite).filter(Boolean) : [];
  fs.writeFileSync(FAVORITES_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

let favoriteAddresses = loadFavoriteAddresses();

function loadRecentAddresses() {
  ensureDataDir();

  try {
    if (!fs.existsSync(RECENTS_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(RECENTS_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed.map(normalizeAddressFavorite).filter(Boolean);
  } catch (error) {
    console.warn("No se pudieron cargar recientes de direcciones:", error.message);
    return [];
  }
}

function saveRecentAddresses(addresses) {
  ensureDataDir();
  const normalized = Array.isArray(addresses) ? addresses.map(normalizeAddressFavorite).filter(Boolean) : [];
  fs.writeFileSync(RECENTS_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

let recentAddresses = loadRecentAddresses();

const defaultAdminPricingConfig = {
  foraneoThresholdKm: 22,
  includedKmInStartFare: 10,
  foraneoMultiplier: 1.5,
  defaultLoadingMinutes: 30,
  defaultTransferMinutes: 20,
  defaultUnloadingMinutes: 30,
  loadPersonnelUnitCost: 80,
  unloadPersonnelUnitCost: 80,
  driverNetDailyTarget: 1200,
  driverWorkHoursPerDay: 8,
  fuelPricePerLiter: 28.22,
  appCommissionRatePct: 25,
  vatRatePct: 16,
  fiscalReserveRatePct: 3,
  maneuverPlatformMarginRate: DEFAULT_MANEUVER_PLATFORM_MARGIN_RATE,
  marketplaceVisibleCategories: ["specialized_1t"],
  driverToPickupDistanceRatio: 0.35,
  categories: {
    pickup_mini: {
      startFare: 150,
      extraKmRate: 18,
      operationalPerMinRate: 4,
      operatingProfile: {
        fuelEfficiencyKmPerLiter: 9,
        avgSpeedKmhNoTraffic: 30,
        maintenancePerKm: 1.2,
        depreciationPerKm: 1.5,
        insurancePerKm: 0.8,
        permitsPerKm: 0.5
      }
    },
    specialized_1t: {
      startFare: 300,
      extraKmRate: 30,
      operationalPerMinRate: 6,
      operatingProfile: {
        fuelEfficiencyKmPerLiter: 8,
        avgSpeedKmhNoTraffic: 28,
        maintenancePerKm: 1.6,
        depreciationPerKm: 2.1,
        insurancePerKm: 1.1,
        permitsPerKm: 0.8
      }
    },
    truck_3t: {
      startFare: 700,
      extraKmRate: 45,
      operationalPerMinRate: 8,
      operatingProfile: {
        fuelEfficiencyKmPerLiter: 5,
        avgSpeedKmhNoTraffic: 24,
        maintenancePerKm: 2.4,
        depreciationPerKm: 3.6,
        insurancePerKm: 1.8,
        permitsPerKm: 1.4
      }
    },
    dump_truck: {
      startFare: 1500,
      extraKmRate: 75,
      operationalPerMinRate: 12,
      operatingProfile: {
        fuelEfficiencyKmPerLiter: 4,
        avgSpeedKmhNoTraffic: 20,
        maintenancePerKm: 3,
        depreciationPerKm: 4.5,
        insurancePerKm: 2.2,
        permitsPerKm: 1.8
      }
    }
  }
};

const defaultAdminVehicleAccessoriesCatalog = [
  "caballetes_marmol",
  "caballetes_vidrio",
  "estructura_acero_tramos",
  "redilas",
  "caja_seca",
  "caja_refrigerada",
  "estructura_cubierta_antilluvia",
  "lona",
  "cinchos",
  "tapetes",
  "hules",
  "carton",
  "plastico_emplaye",
  "tarimas",
  "esquineros_protectores",
  "mantas_aislantes",
  "cinta_seguridad",
  "rampas_carga"
];

let adminVehicleAccessoriesCatalog = [...defaultAdminVehicleAccessoriesCatalog];

function cloneDefaultAdminPricingConfig() {
  return JSON.parse(JSON.stringify(defaultAdminPricingConfig));
}

function normalizeAdminPricingConfig(input) {
  const base = cloneDefaultAdminPricingConfig();
  const data = input && typeof input === "object" ? input : {};

  const toNumberOr = (value, fallback) => {
    const num = Number(value);
    return Number.isFinite(num) ? num : fallback;
  };

  base.foraneoThresholdKm = Math.max(0, toNumberOr(data.foraneoThresholdKm, base.foraneoThresholdKm));
  base.includedKmInStartFare = Math.max(0, toNumberOr(data.includedKmInStartFare, base.includedKmInStartFare));
  base.foraneoMultiplier = Math.max(1, toNumberOr(data.foraneoMultiplier, base.foraneoMultiplier));
  base.defaultLoadingMinutes = Math.max(0, toNumberOr(data.defaultLoadingMinutes, base.defaultLoadingMinutes));
  base.defaultTransferMinutes = Math.max(0, toNumberOr(data.defaultTransferMinutes, base.defaultTransferMinutes));
  base.defaultUnloadingMinutes = Math.max(0, toNumberOr(data.defaultUnloadingMinutes, base.defaultUnloadingMinutes));
  base.loadPersonnelUnitCost = Math.max(0, toNumberOr(data.loadPersonnelUnitCost, base.loadPersonnelUnitCost));
  base.unloadPersonnelUnitCost = Math.max(0, toNumberOr(data.unloadPersonnelUnitCost, base.unloadPersonnelUnitCost));
  base.driverNetDailyTarget = Math.max(0, toNumberOr(data.driverNetDailyTarget, base.driverNetDailyTarget));
  base.driverWorkHoursPerDay = Math.max(1, toNumberOr(data.driverWorkHoursPerDay, base.driverWorkHoursPerDay));
  base.fuelPricePerLiter = Math.max(0, toNumberOr(data.fuelPricePerLiter, base.fuelPricePerLiter));
  base.appCommissionRatePct = Math.max(0, toNumberOr(data.appCommissionRatePct, base.appCommissionRatePct));
  base.vatRatePct = Math.max(0, toNumberOr(data.vatRatePct, base.vatRatePct));
  base.fiscalReserveRatePct = Math.max(0, toNumberOr(data.fiscalReserveRatePct, base.fiscalReserveRatePct));
  base.maneuverPlatformMarginRate = Math.max(0, toNumberOr(data.maneuverPlatformMarginRate, base.maneuverPlatformMarginRate));
  base.marketplaceVisibleCategories = Array.isArray(data.marketplaceVisibleCategories)
    ? [...new Set(
      data.marketplaceVisibleCategories
        .map((value) => String(value || "").trim())
        .filter((value) => Boolean(vehicleCategories[value]))
    )]
    : [...base.marketplaceVisibleCategories];
  if (base.marketplaceVisibleCategories.length === 0) {
    base.marketplaceVisibleCategories = ["specialized_1t"];
  }
  base.driverToPickupDistanceRatio = Math.max(0, toNumberOr(data.driverToPickupDistanceRatio, base.driverToPickupDistanceRatio));

  const srcCategories = data.categories && typeof data.categories === "object" ? data.categories : {};
  Object.keys(base.categories).forEach((key) => {
    const src = srcCategories[key] && typeof srcCategories[key] === "object" ? srcCategories[key] : {};
    base.categories[key].startFare = Math.max(0, toNumberOr(src.startFare, base.categories[key].startFare));
    base.categories[key].extraKmRate = Math.max(0, toNumberOr(src.extraKmRate, base.categories[key].extraKmRate));
    base.categories[key].operationalPerMinRate = Math.max(0, toNumberOr(src.operationalPerMinRate, base.categories[key].operationalPerMinRate));
    const srcProfile = src.operatingProfile && typeof src.operatingProfile === "object"
      ? src.operatingProfile
      : {};
    base.categories[key].operatingProfile.fuelEfficiencyKmPerLiter = Math.max(
      1,
      toNumberOr(
        srcProfile.fuelEfficiencyKmPerLiter,
        base.categories[key].operatingProfile.fuelEfficiencyKmPerLiter
      )
    );
    base.categories[key].operatingProfile.avgSpeedKmhNoTraffic = Math.max(
      5,
      toNumberOr(
        srcProfile.avgSpeedKmhNoTraffic,
        base.categories[key].operatingProfile.avgSpeedKmhNoTraffic
      )
    );
    base.categories[key].operatingProfile.maintenancePerKm = Math.max(
      0,
      toNumberOr(
        srcProfile.maintenancePerKm,
        base.categories[key].operatingProfile.maintenancePerKm
      )
    );
    base.categories[key].operatingProfile.depreciationPerKm = Math.max(
      0,
      toNumberOr(
        srcProfile.depreciationPerKm,
        base.categories[key].operatingProfile.depreciationPerKm
      )
    );
    base.categories[key].operatingProfile.insurancePerKm = Math.max(
      0,
      toNumberOr(
        srcProfile.insurancePerKm,
        base.categories[key].operatingProfile.insurancePerKm
      )
    );
    base.categories[key].operatingProfile.permitsPerKm = Math.max(
      0,
      toNumberOr(
        srcProfile.permitsPerKm,
        base.categories[key].operatingProfile.permitsPerKm
      )
    );
  });

  return base;
}

function loadAdminPricingConfig() {
  ensureDataDir();
  try {
    if (!fs.existsSync(ADMIN_PRICING_FILE)) {
      return cloneDefaultAdminPricingConfig();
    }

    const raw = fs.readFileSync(ADMIN_PRICING_FILE, "utf8");
    if (!raw.trim()) {
      return cloneDefaultAdminPricingConfig();
    }

    const parsed = JSON.parse(raw);
    return normalizeAdminPricingConfig(parsed);
  } catch (error) {
    console.warn("No se pudo cargar configuración administrativa de tarifas:", error.message);
    return cloneDefaultAdminPricingConfig();
  }
}

function saveAdminPricingConfig(config) {
  ensureDataDir();
  const normalized = normalizeAdminPricingConfig(config);
  fs.writeFileSync(ADMIN_PRICING_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function normalizeAdminVehicleRecord(item, { existingId = null } = {}) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const category = String(item.category || "").trim();
  if (!category || !vehicleCategories[category]) {
    return null;
  }

  const plateNumber = String(item.plateNumber || item.plate || "").trim().toUpperCase();
  if (!plateNumber) {
    return null;
  }

  const yearValue = Number(item.year);
  const currentYear = new Date().getFullYear();
  const year = Number.isFinite(yearValue) ? Math.max(1980, Math.min(currentYear + 1, Math.trunc(yearValue))) : null;

  const toPositiveNumberOrNull = (value) => {
    const parsed = Number(value);
    if (!Number.isFinite(parsed) || parsed < 0) {
      return null;
    }
    return Number(parsed.toFixed(2));
  };

  const normalizeDateLike = (value) => {
    const text = String(value || "").trim();
    if (!text) {
      return null;
    }
    if (/^\d{4}-\d{2}-\d{2}$/.test(text)) {
      return text;
    }
    const parsed = new Date(text);
    if (Number.isNaN(parsed.getTime())) {
      return null;
    }
    const month = String(parsed.getMonth() + 1).padStart(2, "0");
    const day = String(parsed.getDate()).padStart(2, "0");
    return `${parsed.getFullYear()}-${month}-${day}`;
  };

  const accessories = Array.isArray(item.accessories)
    ? item.accessories
      .map((entry) => String(entry || "").trim().toLowerCase())
      .filter((entry) => entry && adminVehicleAccessoriesCatalog.includes(entry))
    : [];

  const vehicleDocumentKeys = [
    "tarjeta_circulacion",
    "poliza_seguro",
    "comprobante_domicilio",
    "verificacion"
  ];
  const documentPhotosSource =
    item.documentPhotos && typeof item.documentPhotos === "object"
      ? item.documentPhotos
      : {};
  const documentPhotos = vehicleDocumentKeys.reduce((acc, key) => {
    acc[key] = String(documentPhotosSource[key] || "").trim();
    return acc;
  }, {});

  const nowIso = new Date().toISOString();

  return {
    id: existingId || String(item.id || "").trim() || uuidv4(),
    plateNumber,
    unitNumber: String(item.unitNumber || "").trim(),
    category,
    bodyType: String(item.bodyType || "").trim(),
    brand: String(item.brand || "").trim(),
    model: String(item.model || "").trim(),
    year,
    color: String(item.color || "").trim(),
    capacityKg: toPositiveNumberOrNull(item.capacityKg),
    volumeM3: toPositiveNumberOrNull(item.volumeM3),
    ownerName: String(item.ownerName || "").trim(),
    operatorName: String(item.operatorName || "").trim(),
    contactPhone: String(item.contactPhone || "").trim(),
    insurancePolicy: String(item.insurancePolicy || "").trim(),
    insuranceExpiry: normalizeDateLike(item.insuranceExpiry),
    circulationCardExpiry: normalizeDateLike(item.circulationCardExpiry),
    verificationExpiry: normalizeDateLike(item.verificationExpiry),
    notes: String(item.notes || "").trim(),
    accessories: [...new Set(accessories)],
    documentPhotos,
    allowMissingDocuments: item.allowMissingDocuments === true,
    suspended: item.suspended === true,
    suspensionReason: String(item.suspensionReason || "").trim().slice(0, 500),
    active: item.active !== false,
    createdAt: String(item.createdAt || "").trim() || nowIso,
    updatedAt: nowIso
  };
}

function validateVehicleDocumentCompliance(vehicle) {
  if (!vehicle || typeof vehicle !== "object") {
    return "Datos de vehiculo invalidos";
  }
  if (vehicle.allowMissingDocuments === true) {
    return null;
  }

  const requiredVehicleDocumentKeys = [
    "tarjeta_circulacion",
    "poliza_seguro",
    "comprobante_domicilio",
    "verificacion"
  ];
  const photos =
    vehicle.documentPhotos && typeof vehicle.documentPhotos === "object"
      ? vehicle.documentPhotos
      : {};
  const missing = requiredVehicleDocumentKeys.filter(
    (key) => !String(photos[key] || "").trim()
  );
  if (!missing.length) {
    return null;
  }
  return `Faltan fotos de documentos del vehiculo: ${missing.join(", ")}`;
}

function loadAdminVehicles() {
  ensureDataDir();
  try {
    if (!fs.existsSync(ADMIN_VEHICLES_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(ADMIN_VEHICLES_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map((item) => normalizeAdminVehicleRecord(item, { existingId: String(item?.id || "").trim() || null }))
      .filter(Boolean)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
  } catch (error) {
    console.warn("No se pudo cargar registro de vehiculos admin:", error.message);
    return [];
  }
}

function saveAdminVehicles(records) {
  ensureDataDir();
  const normalized = Array.isArray(records)
    ? records
      .map((item) => normalizeAdminVehicleRecord(item, { existingId: String(item?.id || "").trim() || null }))
      .filter(Boolean)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
    : [];

  fs.writeFileSync(ADMIN_VEHICLES_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

const defaultAdminDriverDocumentKeys = [
  "ine",
  "licencia_vigente",
  "comprobante_domicilio",
  "carta_antecedentes",
  "contrato_firmado",
  "capacitacion_aprobada",
  "seguro_vigente",
  "examen_medico"
];

const defaultAdminDriverSkillsCatalog = [
  "carga_marmol",
  "carga_vidrio",
  "manejo_acero_crudo_tubulares_vigas_ptr",
  "manejo_perfiles_y_estructuras_metalicas",
  "manejo_madera_tableros_triplay",
  "traslado_muebles_y_linea_blanca",
  "manejo_bultos_cemento_mortero_yeso",
  "manejo_material_encostalado",
  "manejo_residuos_peligrosos",
  "sitios_autorizados_escombro_basura",
  "manejo_escombro_y_residuos_de_obra",
  "manejo_minicargador",
  "maniobras_con_montacargas",
  "uso_rampas_patines_diablitos",
  "amarre_y_aseguramiento_carga",
  "habilidad_cargador_maniobrista",
  "solo_chofer_sin_maniobras_carga",
  "maniobras_con_caballetes",
  "estiba_y_desestiba_profesional",
  "proteccion_con_lona_hules_carton_emplaye",
  "uso_cinchos_cadenas_eslingas"
];

let adminDriverDocumentKeys = [...defaultAdminDriverDocumentKeys];
let adminDriverSkillsCatalog = [...defaultAdminDriverSkillsCatalog];

const adminCatalogKeyMap = {
  vehicle_accessories: "vehicleAccessories",
  driver_documents: "driverDocuments",
  driver_skills: "driverSkills"
};

function normalizeCatalogItem(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\s_\-]/g, " ")
    .replace(/[\s\-]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "");
}

function uniqueCatalogItems(items, fallback = []) {
  const source = Array.isArray(items) ? items : fallback;
  const normalized = source
    .map(normalizeCatalogItem)
    .filter((item) => item.length >= 3);
  return [...new Set(normalized)];
}

function normalizeAdminCatalogs(input) {
  const data = input && typeof input === "object" ? input : {};
  return {
    vehicleAccessories: uniqueCatalogItems(
      data.vehicleAccessories,
      defaultAdminVehicleAccessoriesCatalog
    ),
    driverDocuments: uniqueCatalogItems(
      data.driverDocuments,
      defaultAdminDriverDocumentKeys
    ),
    driverSkills: uniqueCatalogItems(
      data.driverSkills,
      defaultAdminDriverSkillsCatalog
    )
  };
}

function loadAdminCatalogs() {
  ensureDataDir();
  try {
    if (!fs.existsSync(ADMIN_CATALOGS_FILE)) {
      return normalizeAdminCatalogs({});
    }

    const raw = fs.readFileSync(ADMIN_CATALOGS_FILE, "utf8");
    if (!raw.trim()) {
      return normalizeAdminCatalogs({});
    }

    const parsed = JSON.parse(raw);
    return normalizeAdminCatalogs(parsed);
  } catch (error) {
    console.warn("No se pudo cargar catálogo admin:", error.message);
    return normalizeAdminCatalogs({});
  }
}

function saveAdminCatalogs(catalogs) {
  ensureDataDir();
  const normalized = normalizeAdminCatalogs(catalogs);
  fs.writeFileSync(ADMIN_CATALOGS_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function applyAdminCatalogs(catalogs) {
  const normalized = normalizeAdminCatalogs(catalogs);
  adminVehicleAccessoriesCatalog = [...normalized.vehicleAccessories];
  adminDriverDocumentKeys = [...normalized.driverDocuments];
  adminDriverSkillsCatalog = [...normalized.driverSkills];
  return normalized;
}

let adminCatalogs = applyAdminCatalogs(loadAdminCatalogs());

function normalizeAdminDriverRecord(item, { existingId = null } = {}) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const requiredString = (value) => String(value || "").trim();
  const existingPinHash = requiredString(item.driverPinHash);
  const firstName = requiredString(item.firstName);
  const lastName = requiredString(item.lastName);
  const phone = normalizePhoneDigits(item.phone);
  const category = requiredString(item.category);
  const licenseNumber = normalizeLicenseNumber(item.licenseNumber);
  const submittedPin = requiredString(item.driverPin || item.pin);
  const driverPinHash = isValidDriverPin(submittedPin)
    ? hashDriverPin(submittedPin)
    : existingPinHash;

  if (!firstName || !lastName || !phone || !category || !licenseNumber || !vehicleCategories[category]) {
    return null;
  }

  const normalizeDateLike = (value) => {
    const text = String(value || "").trim();
    if (!text) {
      return null;
    }
    if (/^\d{4}-\d{2}-\d{2}$/.test(text)) {
      return text;
    }
    const parsed = new Date(text);
    if (Number.isNaN(parsed.getTime())) {
      return null;
    }
    const month = String(parsed.getMonth() + 1).padStart(2, "0");
    const day = String(parsed.getDate()).padStart(2, "0");
    return `${parsed.getFullYear()}-${month}-${day}`;
  };

  const documentsSource = item.documents && typeof item.documents === "object" ? item.documents : {};
  const documents = adminDriverDocumentKeys.reduce((acc, key) => {
    acc[key] = documentsSource[key] === true;
    return acc;
  }, {});

  const documentPhotosSource =
    item.documentPhotos && typeof item.documentPhotos === "object"
      ? item.documentPhotos
      : {};
  const documentPhotos = adminDriverDocumentKeys.reduce((acc, key) => {
    acc[key] = String(documentPhotosSource[key] || "").trim();
    return acc;
  }, {});

  const knownVehicleIds = new Set(adminVehicles.map((vehicle) => vehicle.id));
  const assignedVehicleIds = Array.isArray(item.assignedVehicleIds)
    ? [...new Set(item.assignedVehicleIds.map((id) => String(id || "").trim()).filter((id) => knownVehicleIds.has(id)))]
    : [];

  const cargoSkills = Array.isArray(item.cargoSkills)
    ? [...new Set(
      item.cargoSkills
        .map((value) => String(value || "").trim().toLowerCase())
        .filter((value) => adminDriverSkillsCatalog.includes(value))
    )]
    : [];

  const nowIso = new Date().toISOString();

  return {
    id: existingId || String(item.id || "").trim() || uuidv4(),
    firstName,
    lastName,
    phone,
    email: requiredString(item.email).toLowerCase(),
    curp: requiredString(item.curp).toUpperCase(),
    rfc: requiredString(item.rfc).toUpperCase(),
    birthDate: normalizeDateLike(item.birthDate),
    address: requiredString(item.address),
    municipality: requiredString(item.municipality).toLowerCase(),
    emergencyContactName: requiredString(item.emergencyContactName),
    emergencyContactPhone: requiredString(item.emergencyContactPhone),
    licenseNumber,
    licenseType: requiredString(item.licenseType),
    licenseExpiry: normalizeDateLike(item.licenseExpiry),
    bloodType: requiredString(item.bloodType).toUpperCase(),
    category,
    available: item.available === true,
    suspended: item.suspended === true,
    suspensionReason: requiredString(item.suspensionReason).slice(0, 500),
    active: item.active !== false,
    notes: requiredString(item.notes),
    assignedVehicleIds,
    cargoSkills,
    documents,
    documentPhotos,
    allowMissingDocuments: item.allowMissingDocuments === true,
    driverPinHash,
    createdAt: requiredString(item.createdAt) || nowIso,
    updatedAt: nowIso
  };
}

function validateDriverDocumentCompliance(driver) {
  if (!driver || typeof driver !== "object") {
    return "Datos de chofer invalidos";
  }
  if (driver.allowMissingDocuments === true) {
    return null;
  }

  const documents = driver.documents && typeof driver.documents === "object" ? driver.documents : {};
  const photos =
    driver.documentPhotos && typeof driver.documentPhotos === "object"
      ? driver.documentPhotos
      : {};

  const missingDocs = adminDriverDocumentKeys.filter((key) => documents[key] !== true);
  const missingPhotos = adminDriverDocumentKeys.filter(
    (key) => !String(photos[key] || "").trim()
  );
  if (!missingDocs.length && !missingPhotos.length) {
    return null;
  }

  const messages = [];
  if (missingDocs.length) {
    messages.push(`faltan marcar documentos: ${missingDocs.join(", ")}`);
  }
  if (missingPhotos.length) {
    messages.push(`faltan fotos de documentos: ${missingPhotos.join(", ")}`);
  }
  return messages.join("; ");
}

function loadAdminDrivers() {
  ensureDataDir();
  try {
    if (!fs.existsSync(ADMIN_DRIVERS_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(ADMIN_DRIVERS_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map((item) => normalizeAdminDriverRecord(item, { existingId: String(item?.id || "").trim() || null }))
      .filter(Boolean)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
  } catch (error) {
    console.warn("No se pudo cargar registro de choferes admin:", error.message);
    return [];
  }
}

function saveAdminDrivers(records) {
  ensureDataDir();
  const normalized = Array.isArray(records)
    ? records
      .map((item) => normalizeAdminDriverRecord(item, { existingId: String(item?.id || "").trim() || null }))
      .filter(Boolean)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
    : [];

  fs.writeFileSync(ADMIN_DRIVERS_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function normalizeAdminDriverAuditRecord(item) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const id = String(item.id || "").trim() || uuidv4();
  const driverId = String(item.driverId || "").trim();
  const action = String(item.action || "").trim().toLowerCase();
  if (!driverId || !action) {
    return null;
  }

  const actor = String(item.actor || "admin").trim() || "admin";
  const details = String(item.details || "").trim();
  const createdAt = String(item.createdAt || "").trim() || new Date().toISOString();

  return {
    id,
    driverId,
    action,
    actor,
    details,
    createdAt
  };
}

function loadAdminDriverAudit() {
  ensureDataDir();
  try {
    if (!fs.existsSync(ADMIN_DRIVER_AUDIT_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(ADMIN_DRIVER_AUDIT_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map(normalizeAdminDriverAuditRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  } catch (error) {
    console.warn("No se pudo cargar bitacora de choferes admin:", error.message);
    return [];
  }
}

function saveAdminDriverAudit(records) {
  ensureDataDir();
  const normalized = Array.isArray(records)
    ? records
      .map(normalizeAdminDriverAuditRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 500)
    : [];
  fs.writeFileSync(ADMIN_DRIVER_AUDIT_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function appendAdminDriverAudit({ driverId, action, actor = "admin", details = "" }) {
  const record = normalizeAdminDriverAuditRecord({
    id: uuidv4(),
    driverId,
    action,
    actor,
    details,
    createdAt: new Date().toISOString()
  });
  if (!record) {
    return;
  }
  adminDriverAudit = saveAdminDriverAudit([record, ...adminDriverAudit]);
}

function normalizeAdminSanctionRecord(item) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const id = String(item.id || "").trim() || uuidv4();
  const subjectType = String(item.subjectType || "").trim().toLowerCase();
  const subjectId = String(item.subjectId || "").trim();
  const action = String(item.action || "").trim().toLowerCase();
  const reason = String(item.reason || "").trim().slice(0, 500);
  const actor = String(item.actor || "admin").trim() || "admin";
  const createdAt = String(item.createdAt || "").trim() || new Date().toISOString();

  const allowedSubjectTypes = new Set(["driver", "customer", "vehicle"]);
  if (!allowedSubjectTypes.has(subjectType) || !subjectId || !action) {
    return null;
  }

  return {
    id,
    subjectType,
    subjectId,
    action,
    reason,
    actor,
    createdAt
  };
}

function loadAdminSanctions() {
  ensureDataDir();
  try {
    if (!fs.existsSync(ADMIN_SANCTIONS_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(ADMIN_SANCTIONS_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map(normalizeAdminSanctionRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  } catch (error) {
    console.warn("No se pudo cargar bitacora de sanciones admin:", error.message);
    return [];
  }
}

function saveAdminSanctions(records) {
  ensureDataDir();
  const normalized = Array.isArray(records)
    ? records
      .map(normalizeAdminSanctionRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 5000)
    : [];

  fs.writeFileSync(ADMIN_SANCTIONS_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function appendAdminSanction({ subjectType, subjectId, action, reason = "", actor = "admin" }) {
  const record = normalizeAdminSanctionRecord({
    id: uuidv4(),
    subjectType,
    subjectId,
    action,
    reason,
    actor,
    createdAt: new Date().toISOString()
  });

  if (!record) {
    return null;
  }

  adminSanctions = saveAdminSanctions([record, ...adminSanctions]);
  return record;
}

function normalizeDriverRatingRecord(item) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const rideId = String(item.rideId || "").trim();
  const driverId = String(item.driverId || "").trim();
  const scoreValue = Number(item.score);
  const score = Number.isFinite(scoreValue) ? Math.round(scoreValue) : NaN;
  if (!rideId || !driverId || score < 1 || score > 5) {
    return null;
  }

  const id = String(item.id || "").trim() || uuidv4();
  const comment = String(item.comment || "").trim().slice(0, 500);
  const driverResponse = String(item.driverResponse || "").trim().slice(0, 500);
  const repliedAtRaw = String(item.repliedAt || "").trim();
  const repliedAt = repliedAtRaw ? repliedAtRaw : null;
  const createdAt = String(item.createdAt || "").trim() || new Date().toISOString();

  return {
    id,
    rideId,
    driverId,
    score,
    comment,
    driverResponse,
    repliedAt,
    createdAt
  };
}

function serializeDriverRatingRecord(record, { includeDriverResponse = true } = {}) {
  if (!record || typeof record !== "object") {
    return null;
  }

  return {
    id: record.id,
    rideId: record.rideId,
    driverId: record.driverId,
    score: record.score,
    comment: record.comment,
    ...(includeDriverResponse
      ? {
        driverResponse: record.driverResponse || "",
        repliedAt: record.repliedAt || null
      }
      : {}),
    createdAt: record.createdAt
  };
}

function loadDriverRatings() {
  ensureDataDir();
  try {
    if (!fs.existsSync(DRIVER_RATINGS_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(DRIVER_RATINGS_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map(normalizeDriverRatingRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  } catch (error) {
    console.warn("No se pudo cargar historial de calificaciones de choferes:", error.message);
    return [];
  }
}

function saveDriverRatings(records) {
  ensureDataDir();
  const normalized = Array.isArray(records)
    ? records
      .map(normalizeDriverRatingRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 5000)
    : [];
  fs.writeFileSync(DRIVER_RATINGS_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function summarizeDriverRatings(driverId) {
  const normalizedDriverId = String(driverId || "").trim();
  const items = driverRatings.filter((entry) => entry.driverId === normalizedDriverId);
  const ratingCount = items.length;
  if (!ratingCount) {
    return { ratingCount: 0, averageScore: null };
  }

  const total = items.reduce((sum, entry) => sum + Number(entry.score || 0), 0);
  const averageScore = Number((total / ratingCount).toFixed(2));
  return {
    ratingCount,
    averageScore
  };
}

function applyDriverRatingSummary(driver) {
  if (!driver || typeof driver !== "object") {
    return;
  }

  const summary = summarizeDriverRatings(driver.id);
  if (summary.ratingCount > 0 && Number.isFinite(summary.averageScore)) {
    driver.rating = Number(summary.averageScore).toFixed(2);
    driver.ratingCount = summary.ratingCount;
  } else {
    driver.ratingCount = 0;
    if (!Number.isFinite(Number(driver.rating))) {
      driver.rating = "0.00";
    }
  }
}

function adminDriverWithRating(driver) {
  if (!driver || typeof driver !== "object") {
    return driver;
  }

  const linkedRuntimeDriver = drivers.find((item) => item.id === driver.id);
  const summarySource = linkedRuntimeDriver || {
    id: driver.id,
    rating: linkedRuntimeDriver?.rating || "0.00",
    ratingCount: linkedRuntimeDriver?.ratingCount || 0
  };
  applyDriverRatingSummary(summarySource);

  const payload = { ...driver };
  const pinConfigured = Boolean(String(payload.driverPinHash || "").trim());
  delete payload.driverPinHash;

  return {
    ...payload,
    pinConfigured,
    rating: summarySource.rating,
    ratingCount: summarySource.ratingCount || 0
  };
}

function normalizeCustomerRecord(item, { existingId = null } = {}) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const normalizePhone = (value) => String(value || "").replace(/\D/g, "").trim();
  const phone = normalizePhone(item.phone);
  const nowIso = new Date().toISOString();

  return {
    id: existingId || String(item.id || "").trim() || uuidv4(),
    fullName: String(item.fullName || item.name || "Cliente").trim() || "Cliente",
    phone,
    email: String(item.email || "").trim().toLowerCase(),
    active: item.active !== false,
    suspended: item.suspended === true,
    suspensionReason: String(item.suspensionReason || "").trim(),
    notes: String(item.notes || "").trim(),
    createdAt: String(item.createdAt || "").trim() || nowIso,
    updatedAt: nowIso
  };
}

function loadAdminCustomers() {
  ensureDataDir();
  try {
    if (!fs.existsSync(ADMIN_CUSTOMERS_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(ADMIN_CUSTOMERS_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map((item) => normalizeCustomerRecord(item, { existingId: String(item?.id || "").trim() || null }))
      .filter(Boolean)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
  } catch (error) {
    console.warn("No se pudo cargar registro de clientes admin:", error.message);
    return [];
  }
}

function saveAdminCustomers(records) {
  ensureDataDir();
  const normalized = Array.isArray(records)
    ? records
      .map((item) => normalizeCustomerRecord(item, { existingId: String(item?.id || "").trim() || null }))
      .filter(Boolean)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
    : [];

  fs.writeFileSync(ADMIN_CUSTOMERS_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function normalizeCustomerRatingRecord(item) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const rideId = String(item.rideId || "").trim();
  const customerId = String(item.customerId || "").trim();
  const driverId = String(item.driverId || "").trim();
  const scoreValue = Number(item.score);
  const score = Number.isFinite(scoreValue) ? Math.round(scoreValue) : NaN;
  if (!rideId || !customerId || !driverId || score < 1 || score > 5) {
    return null;
  }

  const id = String(item.id || "").trim() || uuidv4();
  const comment = String(item.comment || "").trim().slice(0, 500);
  const complaintTags = Array.isArray(item.complaintTags)
    ? [...new Set(item.complaintTags.map((tag) => String(tag || "").trim().toLowerCase()).filter(Boolean))].slice(0, 8)
    : [];
  const adminNotes = String(item.adminNotes || "").trim().slice(0, 1000);
  const createdAt = String(item.createdAt || "").trim() || new Date().toISOString();

  return {
    id,
    rideId,
    customerId,
    driverId,
    score,
    comment,
    complaintTags,
    adminNotes,
    createdAt
  };
}

function loadCustomerRatings() {
  ensureDataDir();
  try {
    if (!fs.existsSync(CUSTOMER_RATINGS_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(CUSTOMER_RATINGS_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map(normalizeCustomerRatingRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  } catch (error) {
    console.warn("No se pudo cargar historial de calificaciones a clientes:", error.message);
    return [];
  }
}

function saveCustomerRatings(records) {
  ensureDataDir();
  const normalized = Array.isArray(records)
    ? records
      .map(normalizeCustomerRatingRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 5000)
    : [];
  fs.writeFileSync(CUSTOMER_RATINGS_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function normalizeDriverNotificationDevice(item, { existingId = null } = {}) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const driverId = String(item.driverId || "").trim();
  const token = String(item.token || "").trim();
  if (!driverId || !token) {
    return null;
  }

  const nowIso = new Date().toISOString();
  const platform = String(item.platform || "mobile").trim().toLowerCase() || "mobile";
  const appState = String(item.appState || "unknown").trim().toLowerCase() || "unknown";

  return {
    id: existingId || String(item.id || "").trim() || uuidv4(),
    driverId,
    token,
    platform,
    appState,
    active: item.active !== false,
    createdAt: String(item.createdAt || "").trim() || nowIso,
    updatedAt: nowIso
  };
}

function loadDriverNotificationDevices() {
  ensureDataDir();
  try {
    if (!fs.existsSync(DRIVER_NOTIFICATION_DEVICES_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(DRIVER_NOTIFICATION_DEVICES_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map((item) => normalizeDriverNotificationDevice(item, { existingId: String(item?.id || "").trim() || null }))
      .filter(Boolean)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
  } catch (error) {
    console.warn("No se pudo cargar dispositivos push de chofer:", error.message);
    return [];
  }
}

function saveDriverNotificationDevices(records) {
  ensureDataDir();
  const normalized = Array.isArray(records)
    ? records
      .map((item) => normalizeDriverNotificationDevice(item, { existingId: String(item?.id || "").trim() || null }))
      .filter(Boolean)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
      .slice(0, 25000)
    : [];

  fs.writeFileSync(DRIVER_NOTIFICATION_DEVICES_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function upsertDriverNotificationDevice(payload) {
  const record = normalizeDriverNotificationDevice({
    ...payload,
    createdAt: payload?.createdAt || new Date().toISOString()
  }, {
    existingId: String(payload?.id || "").trim() || null
  });

  if (!record) {
    return null;
  }

  const next = driverNotificationDevices.filter((item) => {
    if (!item || typeof item !== "object") {
      return false;
    }
    if (item.id === record.id) {
      return false;
    }
    if (item.driverId === record.driverId && item.token === record.token) {
      return false;
    }
    return true;
  });

  driverNotificationDevices = saveDriverNotificationDevices([record, ...next]);
  return record;
}

function summarizeCustomerRatings(customerId) {
  const normalizedCustomerId = String(customerId || "").trim();
  const items = customerRatings.filter((entry) => entry.customerId === normalizedCustomerId);
  const ratingCount = items.length;
  if (!ratingCount) {
    return { ratingCount: 0, averageScore: null };
  }

  const total = items.reduce((sum, entry) => sum + Number(entry.score || 0), 0);
  const averageScore = Number((total / ratingCount).toFixed(2));
  return {
    ratingCount,
    averageScore
  };
}

function applyCustomerRatingSummary(customer) {
  if (!customer || typeof customer !== "object") {
    return;
  }

  const summary = summarizeCustomerRatings(customer.id);
  if (summary.ratingCount > 0 && Number.isFinite(summary.averageScore)) {
    customer.rating = Number(summary.averageScore).toFixed(2);
    customer.ratingCount = summary.ratingCount;
  } else {
    customer.rating = "0.00";
    customer.ratingCount = 0;
  }
}

function normalizeIncidentRecord(item) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const id = String(item.id || "").trim() || uuidv4();
  const subjectType = String(item.subjectType || "").trim().toLowerCase();
  const subjectId = String(item.subjectId || "").trim();
  const category = String(item.category || "").trim().toLowerCase();
  const severity = String(item.severity || "media").trim().toLowerCase();
  const title = String(item.title || "").trim();
  const details = String(item.details || "").trim();
  const reportedBy = String(item.reportedBy || "sistema").trim() || "sistema";
  const rideId = String(item.rideId || "").trim();
  const status = String(item.status || "open").trim().toLowerCase();
  const createdAt = String(item.createdAt || "").trim() || new Date().toISOString();

  if (!subjectType || !subjectId || !category || !title) {
    return null;
  }

  const allowedSeverity = new Set(["baja", "media", "alta", "critica"]);
  const allowedStatus = new Set(["open", "in_review", "resolved", "dismissed"]);

  return {
    id,
    subjectType,
    subjectId,
    category,
    severity: allowedSeverity.has(severity) ? severity : "media",
    title,
    details,
    reportedBy,
    rideId,
    status: allowedStatus.has(status) ? status : "open",
    createdAt
  };
}

function loadAdminIncidents() {
  ensureDataDir();
  try {
    if (!fs.existsSync(ADMIN_INCIDENTS_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(ADMIN_INCIDENTS_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map(normalizeIncidentRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  } catch (error) {
    console.warn("No se pudo cargar incidencias administrativas:", error.message);
    return [];
  }
}

function saveAdminIncidents(records) {
  ensureDataDir();
  const normalized = Array.isArray(records)
    ? records
      .map(normalizeIncidentRecord)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 5000)
    : [];

  fs.writeFileSync(ADMIN_INCIDENTS_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function appendAdminIncident(payload) {
  const record = normalizeIncidentRecord({
    ...payload,
    id: uuidv4(),
    createdAt: new Date().toISOString()
  });
  if (!record) {
    return null;
  }

  adminIncidents = saveAdminIncidents([record, ...adminIncidents]);
  return record;
}

function normalizeDriverLedgerEntry(item) {
  if (!item || typeof item !== "object") {
    return null;
  }

  const id = String(item.id || "").trim() || uuidv4();
  const driverId = String(item.driverId || "").trim();
  const rideId = String(item.rideId || "").trim() || null;
  const type = String(item.type || "").trim().toLowerCase();
  const amountValue = Number(item.amount);
  const amount = Number.isFinite(amountValue) ? Number(amountValue.toFixed(2)) : NaN;
  const description = String(item.description || "").trim().slice(0, 500);
  const currency = String(item.currency || "MXN").trim().toUpperCase() || "MXN";
  const createdAt = String(item.createdAt || "").trim() || new Date().toISOString();

  const allowedTypes = new Set([
    "earn",
    "commission",
    "payout",
    "adjustment_credit",
    "adjustment_debit"
  ]);

  if (!driverId || !allowedTypes.has(type) || !Number.isFinite(amount) || amount === 0) {
    return null;
  }

  return {
    id,
    driverId,
    rideId,
    type,
    amount,
    description,
    currency,
    createdAt
  };
}

function loadDriverLedger() {
  ensureDataDir();
  try {
    if (!fs.existsSync(DRIVER_LEDGER_FILE)) {
      return [];
    }

    const raw = fs.readFileSync(DRIVER_LEDGER_FILE, "utf8");
    if (!raw.trim()) {
      return [];
    }

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }

    return parsed
      .map(normalizeDriverLedgerEntry)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  } catch (error) {
    console.warn("No se pudo cargar ledger de choferes:", error.message);
    return [];
  }
}

function saveDriverLedger(entries) {
  ensureDataDir();
  const normalized = Array.isArray(entries)
    ? entries
      .map(normalizeDriverLedgerEntry)
      .filter(Boolean)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 20000)
    : [];

  fs.writeFileSync(DRIVER_LEDGER_FILE, JSON.stringify(normalized, null, 2), "utf8");
  return normalized;
}

function appendDriverLedgerEntry(payload) {
  const record = normalizeDriverLedgerEntry({
    ...payload,
    id: uuidv4(),
    createdAt: new Date().toISOString()
  });
  if (!record) {
    return null;
  }

  driverLedger = saveDriverLedger([record, ...driverLedger]);
  return record;
}

function hasRideSettlementEntries(driverId, rideId) {
  const normalizedDriverId = String(driverId || "").trim();
  const normalizedRideId = String(rideId || "").trim();
  if (!normalizedDriverId || !normalizedRideId) {
    return false;
  }

  return driverLedger.some((entry) =>
    entry.driverId === normalizedDriverId &&
    entry.rideId === normalizedRideId &&
    (entry.type === "earn" || entry.type === "commission")
  );
}

function parseStatementDateRange({ from, to, windowDays = 30 } = {}) {
  const fallbackTo = new Date();
  const fallbackFrom = new Date(fallbackTo.getTime() - Math.max(1, Number(windowDays || 30)) * 24 * 60 * 60 * 1000);
  const parsedFrom = from ? new Date(from) : fallbackFrom;
  const parsedTo = to ? new Date(to) : fallbackTo;
  const fromDate = Number.isNaN(parsedFrom.getTime()) ? fallbackFrom : parsedFrom;
  const toDate = Number.isNaN(parsedTo.getTime()) ? fallbackTo : parsedTo;

  return {
    from: fromDate,
    to: toDate
  };
}

function getDriverLedgerEntries(driverId, { from, to, windowDays = 30, limit = 500 } = {}) {
  const normalizedDriverId = String(driverId || "").trim();
  const { from: fromDate, to: toDate } = parseStatementDateRange({ from, to, windowDays });
  const fromMs = fromDate.getTime();
  const toMs = toDate.getTime();

  const entries = driverLedger
    .filter((entry) => {
      if (entry.driverId !== normalizedDriverId) {
        return false;
      }
      const createdMs = new Date(entry.createdAt).getTime();
      if (Number.isNaN(createdMs)) {
        return false;
      }
      return createdMs >= fromMs && createdMs <= toMs;
    })
    .slice(0, Math.max(1, Math.min(5000, Number(limit) || 500)));

  return {
    entries,
    from: fromDate.toISOString(),
    to: toDate.toISOString()
  };
}

function summarizeDriverLedger(entries) {
  const source = Array.isArray(entries) ? entries : [];
  let grossEarnings = 0;
  let commissions = 0;
  let payouts = 0;
  let adjustments = 0;
  let balance = 0;

  for (const entry of source) {
    const amount = Number(entry.amount || 0);
    if (!Number.isFinite(amount)) {
      continue;
    }

    balance += amount;
    if (entry.type === "earn") {
      grossEarnings += amount;
      continue;
    }
    if (entry.type === "commission") {
      commissions += Math.abs(amount);
      continue;
    }
    if (entry.type === "payout") {
      payouts += Math.abs(amount);
      continue;
    }
    if (entry.type === "adjustment_credit" || entry.type === "adjustment_debit") {
      adjustments += amount;
    }
  }

  const netEarnings = grossEarnings - commissions;

  return {
    grossEarnings: Number(grossEarnings.toFixed(2)),
    commissions: Number(commissions.toFixed(2)),
    netEarnings: Number(netEarnings.toFixed(2)),
    payouts: Number(payouts.toFixed(2)),
    adjustments: Number(adjustments.toFixed(2)),
    balance: Number(balance.toFixed(2))
  };
}

function toCsvValue(value) {
  const text = String(value ?? "");
  if (/[",\n\r]/.test(text)) {
    return `"${text.replace(/"/g, '""')}"`;
  }
  return text;
}

function toCsvString(rows) {
  if (!Array.isArray(rows) || rows.length === 0) {
    return "";
  }
  return rows
    .map((row) => row.map((cell) => toCsvValue(cell)).join(","))
    .join("\n");
}

const cityCenter = { lat: 20.7214, lng: -103.3918 };

const incidentCategoryCatalog = {
  customer: [
    "actitud_agresiva",
    "falta_de_pago",
    "ubicacion_incorrecta",
    "cambio_destino_no_reportado",
    "cancelacion_tardia",
    "riesgo_seguridad",
    "no_presente_en_punto",
    "carga_no_declarada"
  ],
  driver: [
    "actitud_inapropiada",
    "incumplimiento_ruta",
    "retraso_excesivo",
    "mal_manejo_carga",
    "cobro_indebido",
    "ausencia_documentacion",
    "incidente_seguridad"
  ],
  vehicle: [
    "descompostura_mecanica",
    "falla_frenos",
    "falla_llantas",
    "falla_refrigeracion",
    "danos_caja_o_plataforma",
    "falla_electrica",
    "accidente",
    "mantenimiento_vencido"
  ],
  trip: [
    "inconsistencia_direccion",
    "entrega_fallida",
    "carga_danada",
    "demora_operativa",
    "riesgo_en_sitio",
    "disputa_tarifa"
  ]
};

// Catálogo de categorías y vehículos Karryt
const vehicleCategories = {
  pickup_mini: {
    id: "pickup_mini",
    label: "Pick-up Mini",
    capacity: "Hasta 800 kg",
    description: "Vehículos compactos de carga ligera",
    boxSize: "1.80 x 1.50 x 0.45 m",
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
    label: "Pickup Caja Redilas",
    capacity: "Hasta 1.1 tonelada",
    description: "Camionetas especializadas para carga estructurada",
    boxSize: "2.60 x 1.80 x 0.40 m",
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
    label: "Especializada 3 tonelada",
    capacity: "Hasta 3 toneladas",
    description: "Camiones medianos para carga consolidada",
    boxSize: "4.20 x 2.10 x 2.10 m",
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
    capacity: "Hasta 8 toneladas",
    description: "Camiones especializados para carga a granel",
    boxSize: "3.40 x 2.20 x 0.80 m (6 m3 aprox.)",
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

// Reglas administrativas de viaje (editable por supervisor)
const tripRules = {
  regionName: "Guadalajara, Jalisco",
  municipalities: ["guadalajara", "zapopan", "tonala", "tlaquepaque", "tlajomulco"],
  foraneoThresholdKm: 22,
  includedKmInStartFare: 10,
  foraneoMultiplier: 1.5
};

let adminPricingConfig = loadAdminPricingConfig();
let adminVehicles = loadAdminVehicles();
let adminDrivers = loadAdminDrivers();
let adminDriverAudit = loadAdminDriverAudit();
let driverRatings = loadDriverRatings();
let adminCustomers = loadAdminCustomers();
let customerRatings = loadCustomerRatings();
let adminIncidents = loadAdminIncidents();
let adminSanctions = loadAdminSanctions();
let driverLedger = loadDriverLedger();
let driverNotificationDevices = loadDriverNotificationDevices();

function applyAdminPricingConfig(config) {
  const normalized = normalizeAdminPricingConfig(config);

  tripRules.foraneoThresholdKm = Number(normalized.foraneoThresholdKm.toFixed(2));
  tripRules.includedKmInStartFare = Number(normalized.includedKmInStartFare.toFixed(2));
  tripRules.foraneoMultiplier = Number(normalized.foraneoMultiplier.toFixed(2));

  Object.keys(categoryRateCard).forEach((categoryKey) => {
    const categoryConfig = normalized.categories[categoryKey] || normalized.categories.pickup_mini;
    categoryRateCard[categoryKey].startFare = Number(categoryConfig.startFare.toFixed(2));
    categoryRateCard[categoryKey].perKm = Number(categoryConfig.extraKmRate.toFixed(2));
    categoryRateCard[categoryKey].waitPerMin = Number(categoryConfig.operationalPerMinRate.toFixed(2));
  });

  return normalized;
}

adminPricingConfig = applyAdminPricingConfig(adminPricingConfig);

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
    ratingCount: 0,
    category,
    vehicle: { id: vehicle.id, name: vehicle.name },
    capacity: categoryData.capacity,
    lat: cityCenter.lat + (Math.random() - 0.5) * 0.08,
    lng: cityCenter.lng + (Math.random() - 0.5) * 0.08,
    available: true,
    completedRides: Math.floor(Math.random() * 500) + 50
  };
});

function toRuntimeDriverFromAdmin(adminDriver, existingRuntime = null) {
  const category = String(adminDriver.category || "").trim();
  const categoryData = vehicleCategories[category] || vehicleCategories.pickup_mini;
  const fallbackVehicleName =
    categoryData?.vehicles?.[0]?.name ||
    "Vehiculo";

  return {
    id: String(adminDriver.id || "").trim(),
    name: `${String(adminDriver.firstName || "").trim()} ${String(adminDriver.lastName || "").trim()}`.trim() || "Chofer",
    rating: String(adminDriver.rating || existingRuntime?.rating || "0.00"),
    ratingCount: Number(adminDriver.ratingCount || existingRuntime?.ratingCount || 0),
    category,
    vehicle: {
      id: String(adminDriver.assignedVehicleIds?.[0] || existingRuntime?.vehicle?.id || ""),
      name: existingRuntime?.vehicle?.name || fallbackVehicleName
    },
    capacity: categoryData?.capacity || existingRuntime?.capacity || "",
    lat: Number(existingRuntime?.lat || cityCenter.lat + (Math.random() - 0.5) * 0.06),
    lng: Number(existingRuntime?.lng || cityCenter.lng + (Math.random() - 0.5) * 0.06),
    available: adminDriver.available === true,
    completedRides: Number(existingRuntime?.completedRides || 0)
  };
}

function upsertRuntimeDriverFromAdmin(adminDriver) {
  const id = String(adminDriver?.id || "").trim();
  if (!id) {
    return null;
  }

  const existingIndex = drivers.findIndex((item) => item.id === id);
  const existingRuntime = existingIndex >= 0 ? drivers[existingIndex] : null;
  const runtimeDriver = toRuntimeDriverFromAdmin(adminDriver, existingRuntime);

  if (existingIndex >= 0) {
    drivers[existingIndex] = runtimeDriver;
  } else {
    drivers.unshift(runtimeDriver);
  }

  applyDriverRatingSummary(runtimeDriver);
  return runtimeDriver;
}

function removeRuntimeDriverById(driverId) {
  const id = String(driverId || "").trim();
  const index = drivers.findIndex((item) => item.id === id);
  if (index >= 0) {
    drivers.splice(index, 1);
  }
}

adminDrivers.forEach((record) => {
  upsertRuntimeDriverFromAdmin(record);
});

const rides = new Map();
drivers.forEach(applyDriverRatingSummary);
adminCustomers.forEach(applyCustomerRatingSummary);

function distanceKm(a, b) {
  const dx = (a.lat - b.lat) * 111;
  const dy = (a.lng - b.lng) * 85;
  return Math.sqrt(dx * dx + dy * dy);
}

function randomTripDistance() {
  return Number((3 + Math.random() * 35).toFixed(1));
}

function normalizeText(value) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim();
}
function isScopedAddress(value, municipalities = tripRules.municipalities) {
  const text = normalizeText(value);
  if (!text) {
    return false;
  }

  return municipalities.some((municipality) => text.includes(normalizeText(municipality)));
}

function resolveRouteType(pickup, dropoff, distanceKm, rules = tripRules) {
  const pickupInScope = isScopedAddress(pickup, rules.municipalities);
  const dropoffInScope = isScopedAddress(dropoff, rules.municipalities);

  // Esta regla aplica solo a Guadalajara y municipios configurados.
  if (!pickupInScope || !dropoffInScope) {
    return "local";
  }

  const normalizedDistance = Math.max(0, Number(distanceKm) || 0);
  return normalizedDistance > rules.foraneoThresholdKm ? "foraneo" : "local";
}

function getServiceKeyByRouteType(categoryKey, routeType = "local") {
  const services = serviceCatalog[categoryKey] || serviceCatalog.pickup_mini;
  const keys = Object.keys(services);
  if (!keys.length) {
    return "local";
  }

  if (routeType === "foraneo") {
    return keys[1] || keys[0];
  }

  return keys[0];
}

function normalizeRideRequestType(value, { hasScheduledAt = false } = {}) {
  const normalized = String(value || "").trim().toLowerCase();
  if (normalized === "scheduled") {
    return "scheduled";
  }
  if (normalized === "same_day") {
    return "same_day";
  }
  if (normalized === "urgent") {
    return "urgent";
  }
  return hasScheduledAt ? "scheduled" : "urgent";
}

function buildRideRequestLabel(requestType, scheduledAt) {
  if (requestType === "scheduled" && scheduledAt) {
    return `Viaje programado para ${new Date(scheduledAt).toLocaleString("es-MX")}`;
  }
  if (requestType === "same_day") {
    return "Solicitud para transcurso del dia";
  }
  return "Solicitud urgente recibida";
}

function sanitizePhoneE164(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return null;
  }

  const onlyDigits = raw.replace(/\D/g, "");
  if (raw.startsWith("+")) {
    return `+${raw.slice(1).replace(/\D/g, "")}`;
  }

  if (onlyDigits.length === 10) {
    return `+52${onlyDigits}`;
  }

  if (onlyDigits.length >= 11 && onlyDigits.length <= 15) {
    return `+${onlyDigits}`;
  }

  return null;
}

async function sendTwilioMessage({ accountSid, authToken, from, to, body }) {
  if (!accountSid || !authToken || !from || !to || !body) {
    return false;
  }

  if (typeof fetch !== "function") {
    return false;
  }

  const auth = Buffer.from(`${accountSid}:${authToken}`).toString("base64");
  const endpoint = `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`;
  const payload = new URLSearchParams({
    From: from,
    To: to,
    Body: body
  });

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Basic ${auth}`,
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: payload
    });
    return response.ok;
  } catch (_error) {
    return false;
  }
}

function getEligibleOutOfAppDrivers(ride) {
  return adminDrivers.filter((driver) =>
    driver.category === ride.category &&
    driver.active !== false &&
    driver.suspended !== true &&
    driver.available !== true
  );
}

async function sendPushRideOffer(ride, drivers) {
  if (!firebaseAdmin || !Array.isArray(firebaseAdmin.apps) || firebaseAdmin.apps.length === 0) {
    return { deliveredDriverIds: new Set(), attempted: 0 };
  }

  const driverIds = new Set(drivers.map((driver) => String(driver.id || "").trim()).filter(Boolean));
  const targetDevices = driverNotificationDevices.filter((device) =>
    device.active !== false &&
    driverIds.has(String(device.driverId || "").trim()) &&
    String(device.token || "").trim()
  );

  if (!targetDevices.length) {
    return { deliveredDriverIds: new Set(), attempted: 0 };
  }

  const tokenToDriver = new Map();
  const tokens = [];
  for (const device of targetDevices) {
    const token = String(device.token || "").trim();
    if (!token || tokenToDriver.has(token)) {
      continue;
    }
    tokens.push(token);
    tokenToDriver.set(token, String(device.driverId || "").trim());
  }

  if (!tokens.length) {
    return { deliveredDriverIds: new Set(), attempted: 0 };
  }

  const requestTypeLabel = ride.requestType === "same_day"
    ? "Transcurso del dia"
    : ride.requestType === "scheduled"
      ? "Programado"
      : "Urgente";

  const message = {
    tokens,
    notification: {
      title: "Nuevo viaje disponible",
      body: `${requestTypeLabel} · MXN ${Number(ride.fareEstimate || 0).toFixed(2)}`
    },
    data: {
      type: "ride_offer",
      rideId: String(ride.id || ""),
      requestType: String(ride.requestType || "urgent"),
      pickup: String(ride.pickup || ""),
      dropoff: String(ride.dropoff || ""),
      fareEstimate: Number(ride.fareEstimate || 0).toFixed(2)
    }
  };

  const result = await firebaseAdmin.messaging().sendEachForMulticast(message);
  const deliveredDriverIds = new Set();
  const invalidTokens = new Set();

  result.responses.forEach((response, index) => {
    const token = tokens[index];
    const driverId = tokenToDriver.get(token);
    if (response.success) {
      if (driverId) {
        deliveredDriverIds.add(driverId);
      }
      return;
    }

    const code = response.error?.code || "";
    if (code === "messaging/registration-token-not-registered" || code === "messaging/invalid-registration-token") {
      invalidTokens.add(token);
    }
  });

  if (invalidTokens.size) {
    driverNotificationDevices = saveDriverNotificationDevices(
      driverNotificationDevices.map((device) => {
        const token = String(device.token || "").trim();
        if (!invalidTokens.has(token)) {
          return device;
        }
        return {
          ...device,
          active: false,
          updatedAt: new Date().toISOString()
        };
      })
    );
  }

  return {
    deliveredDriverIds,
    attempted: tokens.length
  };
}

async function notifyOfflineDrivers(ride, preferences = {}) {
  const notifyWhatsApp = preferences.whatsapp === true;
  const notifySms = preferences.sms === true;
  const eligible = getEligibleOutOfAppDrivers(ride);
  if (!eligible.length) {
    return;
  }

  const pushResult = await sendPushRideOffer(ride, eligible);
  if (pushResult.deliveredDriverIds.size > 0) {
    return;
  }

  if (!notifyWhatsApp && !notifySms) {
    return;
  }

  const accountSid = String(process.env.TWILIO_ACCOUNT_SID || "").trim();
  const authToken = String(process.env.TWILIO_AUTH_TOKEN || "").trim();
  const fromWhatsApp = String(process.env.TWILIO_WHATSAPP_FROM || "").trim();
  const fromSms = String(process.env.TWILIO_SMS_FROM || "").trim();
  if (!accountSid || !authToken) {
    return;
  }

  const body = [
    "Nuevo viaje disponible en Karryt",
    `Tipo: ${ride.requestType === "same_day" ? "Transcurso del dia" : ride.requestType === "scheduled" ? "Programado" : "Urgente"}`,
    `Origen: ${ride.pickup}`,
    `Destino: ${ride.dropoff}`,
    `Tarifa estimada: MXN ${Number(ride.fareEstimate || 0).toFixed(2)}`,
    "Abre la app de chofer para aceptarlo."
  ].join("\n");

  const jobs = [];
  for (const driver of eligible) {
    const phone = sanitizePhoneE164(driver.phone);
    if (!phone) {
      continue;
    }

    if (notifyWhatsApp && fromWhatsApp) {
      jobs.push(sendTwilioMessage({
        accountSid,
        authToken,
        from: fromWhatsApp.startsWith("whatsapp:") ? fromWhatsApp : `whatsapp:${fromWhatsApp}`,
        to: `whatsapp:${phone}`,
        body
      }));
    }

    if (notifySms && fromSms) {
      jobs.push(sendTwilioMessage({
        accountSid,
        authToken,
        from: fromSms,
        to: phone,
        body
      }));
    }
  }

  if (jobs.length) {
    await Promise.allSettled(jobs);
  }
}

function buildFareBreakdown({
  distance,
  categoryKey,
  serviceKey,
  waitMinutes = 0,
  routeType = "local",
  personnelSurcharge = 0,
  driverToPickupDistanceKm = null
}) {
  const services = serviceCatalog[categoryKey] || serviceCatalog.pickup_mini;
  const service = services[serviceKey] || Object.values(services)[0];
  const rateCard = categoryRateCard[categoryKey] || categoryRateCard.pickup_mini;
  const categoryConfig =
    adminPricingConfig.categories?.[categoryKey] ||
    adminPricingConfig.categories?.pickup_mini ||
    defaultAdminPricingConfig.categories.pickup_mini;
  const operatingProfile = categoryConfig.operatingProfile || defaultAdminPricingConfig.categories.pickup_mini.operatingProfile;

  const normalizedDistance = Math.max(0, Number(distance) || 0); // Distancia B -> C
  const hasExplicitDriverToPickup =
    driverToPickupDistanceKm !== null &&
    driverToPickupDistanceKm !== undefined &&
    String(driverToPickupDistanceKm).trim() !== "";
  const normalizedDriverToPickupDistance = hasExplicitDriverToPickup
    ? Math.max(0, Number(driverToPickupDistanceKm) || 0)
    : Number((normalizedDistance * (Number(adminPricingConfig.driverToPickupDistanceRatio) || 0)).toFixed(2));
  const totalOperationalDistance = normalizedDistance + normalizedDriverToPickupDistance; // A -> B + B -> C
  const normalizedWait = Math.max(0, Number(waitMinutes) || 0);
  const normalizedPersonnel = Math.max(0, Number(personnelSurcharge) || 0);
  const demandFactor = 1 + Math.random() * 0.12;
  const includedKm = Math.max(0, Number(tripRules.includedKmInStartFare) || 0);
  const billableDistance = Math.max(0, normalizedDistance - includedKm);

  const marketSubtotal =
    rateCard.startFare +
    billableDistance * rateCard.perKm +
    normalizedWait * rateCard.waitPerMin +
    normalizedPersonnel;

  const routeMultiplier = routeType === "foraneo" ? tripRules.foraneoMultiplier : 1;
  const marketFare = marketSubtotal * (service.multiplier ?? 1) * routeMultiplier * demandFactor;

  const fuelEfficiencyKmPerLiter = Math.max(1, Number(operatingProfile.fuelEfficiencyKmPerLiter) || 1);
  const fuelPricePerLiter = Math.max(0, Number(adminPricingConfig.fuelPricePerLiter) || 0);
  const fuelLiters = totalOperationalDistance / fuelEfficiencyKmPerLiter;
  const fuelCost = fuelLiters * fuelPricePerLiter;

  const variablePerKm =
    (Number(operatingProfile.maintenancePerKm) || 0) +
    (Number(operatingProfile.depreciationPerKm) || 0) +
    (Number(operatingProfile.insurancePerKm) || 0) +
    (Number(operatingProfile.permitsPerKm) || 0);
  const vehicleVariableCost = totalOperationalDistance * variablePerKm;

  const avgSpeedKmhNoTraffic = Math.max(5, Number(operatingProfile.avgSpeedKmhNoTraffic) || 5);
  const driverToPickupMinutes = (normalizedDriverToPickupDistance / avgSpeedKmhNoTraffic) * 60;
  const operationalMinutesWithDispatch = normalizedWait + driverToPickupMinutes;
  const driverHourlyTarget =
    (Math.max(0, Number(adminPricingConfig.driverNetDailyTarget) || 0) /
      Math.max(1, Number(adminPricingConfig.driverWorkHoursPerDay) || 1));
  const driverTargetForTrip = driverHourlyTarget * (operationalMinutesWithDispatch / 60);

  const operationalCostBase =
    driverTargetForTrip +
    fuelCost +
    vehicleVariableCost +
    normalizedPersonnel;
  const appCommissionCost =
    operationalCostBase * (Math.max(0, Number(adminPricingConfig.appCommissionRatePct) || 0) / 100);
  const fiscalReserveCost =
    operationalCostBase * (Math.max(0, Number(adminPricingConfig.fiscalReserveRatePct) || 0) / 100);

  const preTaxFare = Math.max(marketFare, operationalCostBase + appCommissionCost + fiscalReserveCost);
  const vatAmount = preTaxFare * (Math.max(0, Number(adminPricingConfig.vatRatePct) || 0) / 100);
  const totalFare = preTaxFare + vatAmount;

  return {
    fareEstimate: Number(totalFare.toFixed(2)),
    breakdown: {
      distanceBC: Number(normalizedDistance.toFixed(2)),
      distanceAB: Number(normalizedDriverToPickupDistance.toFixed(2)),
      totalOperationalDistance: Number(totalOperationalDistance.toFixed(2)),
      operationalMinutes: Number(normalizedWait.toFixed(2)),
      driverToPickupMinutes: Number(driverToPickupMinutes.toFixed(2)),
      operationalMinutesWithDispatch: Number(operationalMinutesWithDispatch.toFixed(2)),
      marketFare: Number(marketFare.toFixed(2)),
      operationalCostBase: Number(operationalCostBase.toFixed(2)),
      fuelCost: Number(fuelCost.toFixed(2)),
      fuelLiters: Number(fuelLiters.toFixed(2)),
      vehicleVariableCost: Number(vehicleVariableCost.toFixed(2)),
      driverTargetForTrip: Number(driverTargetForTrip.toFixed(2)),
      appCommissionCost: Number(appCommissionCost.toFixed(2)),
      fiscalReserveCost: Number(fiscalReserveCost.toFixed(2)),
      preTaxFare: Number(preTaxFare.toFixed(2)),
      vatAmount: Number(vatAmount.toFixed(2)),
      serviceMultiplier: Number((service.multiplier ?? 1).toFixed(3)),
      routeMultiplier: Number(routeMultiplier.toFixed(3)),
      demandFactor: Number(demandFactor.toFixed(3)),
      appCommissionRatePct: Number((Number(adminPricingConfig.appCommissionRatePct) || 0).toFixed(2)),
      vatRatePct: Number((Number(adminPricingConfig.vatRatePct) || 0).toFixed(2)),
      fiscalReserveRatePct: Number((Number(adminPricingConfig.fiscalReserveRatePct) || 0).toFixed(2)),
      driverHourlyTarget: Number(driverHourlyTarget.toFixed(2)),
      fuelEfficiencyKmPerLiter: Number(fuelEfficiencyKmPerLiter.toFixed(2)),
      fuelPricePerLiter: Number(fuelPricePerLiter.toFixed(2)),
      avgSpeedKmhNoTraffic: Number(avgSpeedKmhNoTraffic.toFixed(2)),
      variablePerKm: Number(variablePerKm.toFixed(2))
    }
  };
}

function resolveOptionalManeuverCharge({
  selectedValue,
  distanceMetersValue,
  maxDistanceMeters = DEFAULT_MANEUVER_MAX_DISTANCE_METERS,
  loaderPayPerTrip = DEFAULT_MANEUVER_LOADER_PAY_PER_TRIP,
  platformMarginRate = DEFAULT_MANEUVER_PLATFORM_MARGIN_RATE
}) {
  const selected = parseBooleanEnv(selectedValue, false);
  const hasDistanceValue =
    distanceMetersValue !== undefined &&
    distanceMetersValue !== null &&
    String(distanceMetersValue).trim() !== "";
  const normalizedDistanceMeters = hasDistanceValue
    ? Number(distanceMetersValue)
    : null;

  if (selected && !Number.isFinite(normalizedDistanceMeters)) {
    return {
      selected,
      valid: false,
      error: "Si seleccionas maniobra de carga/descarga debes indicar distanceMeters válido."
    };
  }

  const distanceMeters = Number.isFinite(normalizedDistanceMeters)
    ? Math.max(0, Number(normalizedDistanceMeters) || 0)
    : 0;
  const eligible = selected && distanceMeters <= maxDistanceMeters;
  const normalizedLoaderPayPerTrip = Math.max(0, Number(loaderPayPerTrip) || 0);
  const normalizedPlatformMarginRate = Math.max(0, Number(platformMarginRate) || 0);
  const platformMarginAmount = normalizedLoaderPayPerTrip * normalizedPlatformMarginRate;
  const chargeToCustomerPerTrip = normalizedLoaderPayPerTrip + platformMarginAmount;

  if (selected && !eligible) {
    return {
      selected,
      valid: false,
      error: `La maniobra de carga/descarga solo aplica hasta ${maxDistanceMeters} metros del vehículo.`
    };
  }

  return {
    selected,
    valid: true,
    distanceMeters: Number(distanceMeters.toFixed(2)),
    eligible,
    loaderPayPerTrip: Number(normalizedLoaderPayPerTrip.toFixed(2)),
    platformMarginRate: Number(normalizedPlatformMarginRate.toFixed(4)),
    platformMarginAmount: Number(platformMarginAmount.toFixed(2)),
    surcharge: eligible ? Number(chargeToCustomerPerTrip.toFixed(2)) : 0,
    maxDistanceMeters: Number(maxDistanceMeters.toFixed(2)),
    chargeToCustomerPerTrip: Number(chargeToCustomerPerTrip.toFixed(2))
  };
}

function estimateFare(
  distance,
  categoryKey,
  serviceKey,
  waitMinutes = 0,
  routeType = "local",
  personnelSurcharge = 0,
  driverToPickupDistanceKm = null
) {
  return buildFareBreakdown({
    distance,
    categoryKey,
    serviceKey,
    waitMinutes,
    routeType,
    personnelSurcharge,
    driverToPickupDistanceKm
  }).fareEstimate;
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
    routeType: ride.routeType,
    status: ride.status,
    assignmentState: ride.assignmentState || "searching",
    requestType: ride.requestType || "urgent",
    maneuverSelected: ride.maneuverSelected === true,
    maneuverDistanceMeters: Number(ride.maneuverDistanceMeters || 0),
    maneuverSurcharge: Number(ride.maneuverSurcharge || 0),
    requestedAt: ride.requestedAt,
    scheduledAt: ride.scheduledAt || null,
    fareEstimate: ride.fareEstimate,
    tripDistanceKm: ride.tripDistanceKm,
    etaMin: ride.etaMin,
    driver: ride.driver,
    customer: ride.customer || null,
    riderRating: ride.riderRating || null,
    driverRatedCustomer: ride.driverRatedCustomer === true,
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

function hasAvailableDriverForCategory(category) {
  return drivers.some((driver) => driver.available && driver.category === category);
}

function markRideAsPendingDriver(ride) {
  if (!ride || ride.driver?.id || ride.status !== "searching") {
    return;
  }

  ride.status = "pending_driver";
  ride.assignmentState = "waiting_driver";
  appendTimeline(ride, "No hay chofer disponible por ahora. Te asignaremos uno en cuanto se conecte.");
  broadcastRide(ride);
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

function findCustomerByPhone(phone) {
  const normalizedPhone = String(phone || "").replace(/\D/g, "").trim();
  if (!normalizedPhone) {
    return null;
  }

  return adminCustomers.find((item) => item.phone === normalizedPhone) || null;
}

function ensureCustomerRecord({ id, fullName, phone }) {
  const normalizedId = String(id || "").trim();
  const normalizedPhone = String(phone || "").replace(/\D/g, "").trim();
  const normalizedName = String(fullName || "").trim() || "Cliente";

  if (normalizedId) {
    const byId = adminCustomers.find((item) => item.id === normalizedId);
    if (byId) {
      const mergedById = normalizeCustomerRecord({
        ...byId,
        fullName: normalizedName || byId.fullName,
        phone: normalizedPhone || byId.phone,
        updatedAt: new Date().toISOString()
      }, { existingId: normalizedId });
      adminCustomers = saveAdminCustomers(
        adminCustomers.map((item) => (item.id === normalizedId ? mergedById : item))
      );
      applyCustomerRatingSummary(mergedById);
      return mergedById;
    }
  }

  const existing = findCustomerByPhone(normalizedPhone);
  if (existing) {
    const merged = normalizeCustomerRecord({
      ...existing,
      fullName: existing.fullName || normalizedName,
      phone: existing.phone || normalizedPhone,
      updatedAt: new Date().toISOString()
    }, { existingId: existing.id });
    adminCustomers = saveAdminCustomers(
      adminCustomers.map((item) => (item.id === existing.id ? merged : item))
    );
    applyCustomerRatingSummary(merged);
    return merged;
  }

  const created = normalizeCustomerRecord({
    id: normalizedId,
    fullName: normalizedName,
    phone: normalizedPhone,
    active: true,
    suspended: false
  });

  adminCustomers = saveAdminCustomers([created, ...adminCustomers]);
  applyCustomerRatingSummary(created);
  return created;
}

function serializeRideCustomer(customer) {
  if (!customer || typeof customer !== "object") {
    return null;
  }

  return {
    id: customer.id,
    fullName: customer.fullName,
    phone: customer.phone,
    active: customer.active !== false,
    suspended: customer.suspended === true,
    rating: customer.rating || "0.00",
    ratingCount: customer.ratingCount || 0
  };
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
          applyDriverRatingSummary(driverObj);
          driverObj.available = true;
          driverObj.completedRides += 1;
          current.driver.rating = driverObj.rating;
          current.driver.ratingCount = driverObj.ratingCount || 0;
        }
        current.etaMin = 0;
      }

      broadcastRide(current);
      broadcastDrivers();
    }, step.delay);
  });
}

// Endpoints API

app.get("/api/addresses/search", async (req, res) => {
  const query = String(req.query.query || req.query.q || "").trim();
  if (query.length < 3) {
    return res.json({ suggestions: [] });
  }

  const biasLat = Number(req.query.biasLat);
  const biasLng = Number(req.query.biasLng);
  const bias = {
    biasLat: Number.isFinite(biasLat) ? biasLat : undefined,
    biasLng: Number.isFinite(biasLng) ? biasLng : undefined
  };

  try {
    const suggestions = [];

    if (shouldRunAddressValidation(query)) {
      const validatedSuggestion = await fetchGoogleValidatedAddressSuggestion(query);
      if (validatedSuggestion) {
        suggestions.push(validatedSuggestion);
      }
    }

    for (const variant of buildAddressSearchQueries(query).slice(0, 5)) {
      const autocompleteSuggestions = await fetchGoogleAutocompleteSuggestions(variant, bias);
      if (autocompleteSuggestions.length > 0) {
        suggestions.push(...autocompleteSuggestions);
        break;
      }
    }

    if (suggestions.length === 0) {
      const nominatimSuggestions = await fetchNominatimSuggestions(query, bias);
      suggestions.push(...nominatimSuggestions);
    }

    const rankedSuggestions = rankAddressSuggestionsByQuery(
      query,
      dedupeAddressSuggestions(suggestions)
    ).slice(0, 8);

    return res.json({ suggestions: rankedSuggestions });
  } catch (error) {
    console.error("Error buscando direcciones:", error.message);
    return res.status(500).json({ error: "No se pudieron consultar direcciones" });
  }
});

app.get("/api/addresses/resolve", async (req, res) => {
  const placeId = String(req.query.placeId || "").trim();
  if (!placeId) {
    return res.status(400).json({ error: "placeId es requerido" });
  }

  try {
    const suggestion = await fetchGooglePlaceDetails(placeId, {
      displayName: req.query.displayName,
      primaryText: req.query.primaryText,
      secondaryText: req.query.secondaryText
    });
    if (!suggestion) {
      return res.status(404).json({ error: "No se pudo resolver la direccion" });
    }
    return res.json(suggestion);
  } catch (error) {
    console.error("Error resolviendo direccion:", error.message);
    return res.status(500).json({ error: "No se pudo resolver la direccion" });
  }
});

app.get("/api/addresses/reverse", async (req, res) => {
  const lat = Number(req.query.lat);
  const lng = Number(req.query.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return res.status(400).json({ error: "lat y lng son requeridos" });
  }

  try {
    let displayName = await reverseGeocodeGoogle(lat, lng);
    displayName = displayName || await reverseGeocodeNominatim(lat, lng);

    if (!displayName) {
      return res.status(404).json({ error: "No se pudo resolver la direccion" });
    }

    return res.json({ displayName });
  } catch (error) {
    console.error("Error resolviendo direccion inversa:", error.message);
    return res.status(500).json({ error: "No se pudo resolver la direccion" });
  }
});

function getVisibleCategoryKeysForMarketplace() {
  const configured = Array.isArray(adminPricingConfig.marketplaceVisibleCategories)
    ? adminPricingConfig.marketplaceVisibleCategories
    : ["specialized_1t"];

  return [...new Set(
    configured
      .map((value) => String(value || "").trim())
      .filter((key) => Boolean(vehicleCategories[key]))
  )];
}

function getVisibleCategoriesMap() {
  return getVisibleCategoryKeysForMarketplace().reduce((acc, key) => {
    acc[key] = vehicleCategories[key];
    return acc;
  }, {});
}

app.get("/api/categories", (_req, res) => {
  res.json(getVisibleCategoriesMap());
});

app.get("/api/services/:category", (req, res) => {
  const visibleCategories = new Set(getVisibleCategoryKeysForMarketplace());
  if (!visibleCategories.has(req.params.category)) {
    return res.status(404).json({ error: "Categoría no disponible por ahora" });
  }

  const services = serviceCatalog[req.params.category];
  if (!services) {
    return res.status(404).json({ error: "Categoría no encontrada" });
  }
  res.json(services);
});

app.get("/api/pricing", (_req, res) => {
  const visibleCategories = new Set(getVisibleCategoryKeysForMarketplace());
  const pricing = Object.entries(categoryRateCard)
    .filter(([categoryKey]) => visibleCategories.has(categoryKey))
    .map(([categoryKey, rates]) => ({
    category: categoryKey,
    categoryLabel: vehicleCategories[categoryKey]?.label || categoryKey,
    startFare: rates.startFare,
    perKmRate: rates.perKm,
    waitPerMinRate: rates.waitPerMin,
    includedKmInStartFare: tripRules.includedKmInStartFare,
    currency: "MXN"
    }));
  res.json(pricing);
});

app.get("/api/drivers", (_req, res) => {
  drivers.forEach(applyDriverRatingSummary);
  return res.json(drivers);
});

app.get("/api/drivers/:id/ratings", (req, res) => {
  const id = String(req.params.id || "").trim();
  const limit = Math.max(1, Math.min(100, Number(req.query.limit) || 20));
  const driver = drivers.find((item) => item.id === id);
  if (!driver) {
    return res.status(404).json({ error: "Conductor no encontrado" });
  }

  applyDriverRatingSummary(driver);
  const items = driverRatings
    .filter((entry) => entry.driverId === id)
    .slice(0, limit)
    .map((entry) => serializeDriverRatingRecord(entry, { includeDriverResponse: true }));

  return res.json({
    driverId: id,
    rating: driver.rating,
    ratingCount: driver.ratingCount || 0,
    ratings: items
  });
});

app.use("/api/admin", requireAnyRole("admin"));
app.use("/api/driver", requireAnyRole("driver", "admin"));

app.post("/api/driver/profile-auth/link", (req, res) => {
  const phone = normalizePhoneDigits(req.body?.phone);
  const licenseNumber = normalizeLicenseNumber(req.body?.licenseNumber);
  const pin = String(req.body?.pin || "").trim();

  if (!phone || !licenseNumber || !isValidDriverPin(pin)) {
    return res.status(400).json({ error: "Debes enviar telefono, licencia y PIN de 4 digitos." });
  }

  const adminDriver = adminDrivers.find((item) =>
    normalizePhoneDigits(item.phone) === phone &&
    normalizeLicenseNumber(item.licenseNumber) === licenseNumber
  );

  if (!adminDriver) {
    return res.status(404).json({ error: "No se encontro un chofer con esos datos." });
  }

  const hasPin = Boolean(String(adminDriver.driverPinHash || "").trim());
  if (hasPin && adminDriver.driverPinHash !== hashDriverPin(pin)) {
    return res.status(401).json({ error: "PIN incorrecto." });
  }

  let normalizedDriver = adminDriver;
  if (!hasPin) {
    const merged = normalizeAdminDriverRecord({
      ...adminDriver,
      driverPin: pin
    }, { existingId: adminDriver.id });
    adminDrivers = saveAdminDrivers(adminDrivers.map((item) => (item.id === adminDriver.id ? merged : item)));
    normalizedDriver = merged;
    appendAdminDriverAudit({
      driverId: merged.id,
      action: "pin_setup",
      details: "PIN de chofer configurado desde app de chofer"
    });
  }

  const runtimeDriver = upsertRuntimeDriverFromAdmin(normalizedDriver);
  broadcastDrivers();
  return res.json({
    ok: true,
    driver: runtimeDriver
  });
});

app.post("/api/driver/profile-auth/unlock", (req, res) => {
  const driverId = String(req.body?.driverId || "").trim();
  const pin = String(req.body?.pin || "").trim();

  if (!driverId || !isValidDriverPin(pin)) {
    return res.status(400).json({ error: "Debes enviar driverId y PIN de 4 digitos." });
  }

  const adminDriver = adminDrivers.find((item) => item.id === driverId);
  if (!adminDriver) {
    return res.status(404).json({ error: "Chofer no encontrado para validar PIN." });
  }

  const expectedHash = String(adminDriver.driverPinHash || "").trim();
  if (!expectedHash) {
    return res.status(428).json({ error: "Este chofer no tiene PIN configurado." });
  }

  if (expectedHash !== hashDriverPin(pin)) {
    return res.status(401).json({ error: "PIN incorrecto." });
  }

  const runtimeDriver = upsertRuntimeDriverFromAdmin(adminDriver);
  return res.json({ ok: true, driver: runtimeDriver });
});

app.get("/api/driver/ratings", (req, res) => {
  const driverId = String(req.query.driverId || "").trim();
  if (!driverId) {
    return res.status(400).json({ error: "driverId es requerido" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "driver", actorId: driverId, actorLabel: "chofer" })) {
    return;
  }

  const limit = Math.max(1, Math.min(100, Number(req.query.limit) || 30));
  const driver = drivers.find((item) => item.id === driverId);
  if (!driver) {
    return res.status(404).json({ error: "Conductor no encontrado" });
  }

  applyDriverRatingSummary(driver);
  const ratings = driverRatings
    .filter((entry) => entry.driverId === driverId)
    .slice(0, limit)
    .map((entry) => serializeDriverRatingRecord(entry, { includeDriverResponse: true }));

  return res.json({
    driverId,
    rating: driver.rating,
    ratingCount: driver.ratingCount || 0,
    ratings
  });
});

app.post("/api/driver/ratings/:id/reply", (req, res) => {
  const id = String(req.params.id || "").trim();
  const driverId = String(req.body?.driverId || "").trim();
  const responseText = String(req.body?.response || "").trim().slice(0, 500);

  if (!driverId) {
    return res.status(400).json({ error: "driverId es requerido" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "driver", actorId: driverId, actorLabel: "chofer" })) {
    return;
  }

  if (!responseText) {
    return res.status(400).json({ error: "response es requerido" });
  }

  const rating = driverRatings.find((entry) => entry.id === id);
  if (!rating) {
    return res.status(404).json({ error: "Calificacion no encontrada" });
  }

  if (rating.driverId !== driverId) {
    return res.status(403).json({ error: "No puedes responder calificaciones de otro conductor" });
  }

  const updated = {
    ...rating,
    driverResponse: responseText,
    repliedAt: new Date().toISOString()
  };

  driverRatings = saveDriverRatings(
    driverRatings.map((entry) => (entry.id === id ? updated : entry))
  );

  const ride = rides.get(rating.rideId);
  if (ride && ride.driver?.id === driverId) {
    appendTimeline(ride, "Conductor respondio la calificacion del viaje");
    broadcastRide(ride);
  }

  return res.json({
    ok: true,
    rating: serializeDriverRatingRecord(updated, { includeDriverResponse: true })
  });
});

app.get("/api/admin/ratings/distribution", (_req, res) => {
  const distribution = {
    5: 0,
    4: 0,
    3: 0,
    2: 0,
    1: 0
  };

  let totalScore = 0;
  let withoutReply = 0;

  for (const entry of driverRatings) {
    const score = Math.max(1, Math.min(5, Number(entry.score) || 0));
    distribution[score] += 1;
    totalScore += score;
    if (!String(entry.driverResponse || "").trim()) {
      withoutReply += 1;
    }
  }

  const total = driverRatings.length;
  return res.json({
    total,
    average: total > 0 ? Number((totalScore / total).toFixed(2)) : 0,
    withoutReply,
    distribution
  });
});

app.patch("/api/drivers/:id/availability", (req, res) => {
  const { id } = req.params;
  const available = req.body?.available;

  if (typeof available !== "boolean") {
    return res.status(400).json({ error: "available debe ser boolean" });
  }

  const driver = drivers.find((item) => item.id === id);
  if (!driver) {
    return res.status(404).json({ error: "Conductor no encontrado" });
  }

  driver.available = available;

  const adminIndex = adminDrivers.findIndex((item) => item.id === id);
  if (adminIndex >= 0) {
    const normalized = normalizeAdminDriverRecord(
      { ...adminDrivers[adminIndex], available },
      { existingId: id }
    );
    adminDrivers[adminIndex] = normalized;
    adminDrivers = saveAdminDrivers(adminDrivers);
  }

  broadcastDrivers();
  return res.json(driver);
});

app.get("/api/address-favorites", (_req, res) => {
  res.json({ favorites: favoriteAddresses });
});

app.put("/api/address-favorites", (req, res) => {
  const payload = req.body;
  const items = Array.isArray(payload?.favorites) ? payload.favorites : [];
  const normalized = items.map(normalizeAddressFavorite).filter(Boolean);

  if (!Array.isArray(items)) {
    return res.status(400).json({ error: "favorites debe ser un arreglo" });
  }

  favoriteAddresses = saveFavoriteAddresses(normalized);
  return res.json({ ok: true, favorites: favoriteAddresses });
});

app.get("/api/address-recents", (_req, res) => {
  res.json({ recents: recentAddresses });
});

app.put("/api/address-recents", (req, res) => {
  const payload = req.body;
  const items = Array.isArray(payload?.recents) ? payload.recents : [];
  const normalized = items.map(normalizeAddressFavorite).filter(Boolean);

  if (!Array.isArray(items)) {
    return res.status(400).json({ error: "recents debe ser un arreglo" });
  }

  recentAddresses = saveRecentAddresses(normalized);
  return res.json({ ok: true, recents: recentAddresses });
});

app.get("/api/trip-rules", (_req, res) => {
  return res.json({
    ...tripRules,
    municipalities: [...tripRules.municipalities]
  });
});

app.put("/api/admin/trip-rules", (req, res) => {
  const payload = req.body || {};
  const foraneoThresholdKm = Number(payload.foraneoThresholdKm);
  const includedKmInStartFare = Number(payload.includedKmInStartFare);
  const foraneoMultiplier = Number(payload.foraneoMultiplier);
  const municipalities = Array.isArray(payload.municipalities)
    ? payload.municipalities.map((item) => normalizeText(item)).filter(Boolean)
    : [];

  if (!Number.isFinite(foraneoThresholdKm) || foraneoThresholdKm < 0) {
    return res.status(400).json({ error: "foraneoThresholdKm inválido" });
  }

  if (!Number.isFinite(includedKmInStartFare) || includedKmInStartFare < 0) {
    return res.status(400).json({ error: "includedKmInStartFare inválido" });
  }

  if (!Number.isFinite(foraneoMultiplier) || foraneoMultiplier < 1) {
    return res.status(400).json({ error: "foraneoMultiplier inválido" });
  }

  if (!municipalities.length) {
    return res.status(400).json({ error: "Debes enviar al menos un municipio" });
  }

  tripRules.foraneoThresholdKm = Number(foraneoThresholdKm.toFixed(2));
  tripRules.includedKmInStartFare = Number(includedKmInStartFare.toFixed(2));
  tripRules.foraneoMultiplier = Number(foraneoMultiplier.toFixed(2));
  tripRules.municipalities = municipalities;

  adminPricingConfig.foraneoThresholdKm = tripRules.foraneoThresholdKm;
  adminPricingConfig.includedKmInStartFare = tripRules.includedKmInStartFare;
  adminPricingConfig.foraneoMultiplier = tripRules.foraneoMultiplier;
  adminPricingConfig = saveAdminPricingConfig(adminPricingConfig);

  return res.json({
    ok: true,
    tripRules: {
      ...tripRules,
      municipalities: [...tripRules.municipalities]
    }
  });
});

app.get("/api/admin/pricing-config", (_req, res) => {
  return res.json({
    ...adminPricingConfig,
    categories: { ...adminPricingConfig.categories },
    municipalities: [...tripRules.municipalities]
  });
});

app.get("/api/admin/catalogs", (_req, res) => {
  return res.json({
    vehicle_accessories: [...adminVehicleAccessoriesCatalog],
    driver_documents: [...adminDriverDocumentKeys],
    driver_skills: [...adminDriverSkillsCatalog]
  });
});

function serializeAdminCatalogs() {
  return {
    vehicle_accessories: [...adminVehicleAccessoriesCatalog],
    driver_documents: [...adminDriverDocumentKeys],
    driver_skills: [...adminDriverSkillsCatalog]
  };
}

app.post("/api/admin/catalogs/:catalogKey/entries", (req, res) => {
  const rawKey = String(req.params.catalogKey || "").trim().toLowerCase();
  const catalogProp = adminCatalogKeyMap[rawKey];
  if (!catalogProp) {
    return res.status(404).json({ error: "Catalogo no encontrado" });
  }

  const item = normalizeCatalogItem(req.body?.item);
  if (!item || item.length < 3) {
    return res.status(400).json({ error: "Entrada de catalogo invalida" });
  }

  const current = normalizeAdminCatalogs(adminCatalogs);
  const merged = {
    ...current,
    [catalogProp]: uniqueCatalogItems([...(current[catalogProp] || []), item])
  };

  adminCatalogs = saveAdminCatalogs(merged);
  adminCatalogs = applyAdminCatalogs(adminCatalogs);

  return res.status(201).json({
    ok: true,
    catalogKey: rawKey,
    item,
    catalogs: serializeAdminCatalogs()
  });
});

app.patch("/api/admin/catalogs/:catalogKey/entries", (req, res) => {
  const rawKey = String(req.params.catalogKey || "").trim().toLowerCase();
  const catalogProp = adminCatalogKeyMap[rawKey];
  if (!catalogProp) {
    return res.status(404).json({ error: "Catalogo no encontrado" });
  }

  const oldItem = normalizeCatalogItem(req.body?.oldItem);
  const newItem = normalizeCatalogItem(req.body?.newItem);
  if (!oldItem || !newItem || newItem.length < 3) {
    return res.status(400).json({ error: "Parametros oldItem/newItem invalidos" });
  }

  const current = normalizeAdminCatalogs(adminCatalogs);
  const source = [...(current[catalogProp] || [])];
  if (!source.includes(oldItem)) {
    return res.status(404).json({ error: "Entrada no encontrada" });
  }

  const replaced = source.map((item) => (item === oldItem ? newItem : item));
  const merged = {
    ...current,
    [catalogProp]: uniqueCatalogItems(replaced)
  };

  adminCatalogs = saveAdminCatalogs(merged);
  adminCatalogs = applyAdminCatalogs(adminCatalogs);

  return res.json({
    ok: true,
    catalogKey: rawKey,
    oldItem,
    item: newItem,
    catalogs: serializeAdminCatalogs()
  });
});

app.delete("/api/admin/catalogs/:catalogKey/entries", (req, res) => {
  const rawKey = String(req.params.catalogKey || "").trim().toLowerCase();
  const catalogProp = adminCatalogKeyMap[rawKey];
  if (!catalogProp) {
    return res.status(404).json({ error: "Catalogo no encontrado" });
  }

  const item = normalizeCatalogItem(req.body?.item);
  if (!item) {
    return res.status(400).json({ error: "Entrada de catalogo invalida" });
  }

  const current = normalizeAdminCatalogs(adminCatalogs);
  const source = [...(current[catalogProp] || [])];
  if (!source.includes(item)) {
    return res.status(404).json({ error: "Entrada no encontrada" });
  }

  if (source.length <= 1) {
    return res.status(400).json({ error: "No puedes dejar este catalogo vacio" });
  }

  const merged = {
    ...current,
    [catalogProp]: source.filter((entry) => entry !== item)
  };

  adminCatalogs = saveAdminCatalogs(merged);
  adminCatalogs = applyAdminCatalogs(adminCatalogs);

  return res.json({
    ok: true,
    catalogKey: rawKey,
    item,
    catalogs: serializeAdminCatalogs()
  });
});

app.post("/api/admin/catalogs/:catalogKey/reorder", (req, res) => {
  const rawKey = String(req.params.catalogKey || "").trim().toLowerCase();
  const catalogProp = adminCatalogKeyMap[rawKey];
  if (!catalogProp) {
    return res.status(404).json({ error: "Catalogo no encontrado" });
  }

  const item = normalizeCatalogItem(req.body?.item);
  const direction = String(req.body?.direction || "").trim().toLowerCase();
  if (!item || (direction !== "up" && direction !== "down")) {
    return res.status(400).json({ error: "Parametros de reordenamiento invalidos" });
  }

  const current = normalizeAdminCatalogs(adminCatalogs);
  const source = [...(current[catalogProp] || [])];
  const index = source.indexOf(item);
  if (index < 0) {
    return res.status(404).json({ error: "Entrada no encontrada" });
  }

  const targetIndex = direction === "up" ? index - 1 : index + 1;
  if (targetIndex < 0 || targetIndex >= source.length) {
    return res.json({ ok: true, catalogKey: rawKey, item, catalogs: serializeAdminCatalogs() });
  }

  const reordered = [...source];
  const temp = reordered[targetIndex];
  reordered[targetIndex] = reordered[index];
  reordered[index] = temp;

  const merged = {
    ...current,
    [catalogProp]: reordered
  };

  adminCatalogs = saveAdminCatalogs(merged);
  adminCatalogs = applyAdminCatalogs(adminCatalogs);

  return res.json({
    ok: true,
    catalogKey: rawKey,
    item,
    direction,
    catalogs: serializeAdminCatalogs()
  });
});

app.put("/api/admin/catalogs/:catalogKey/order", (req, res) => {
  const rawKey = String(req.params.catalogKey || "").trim().toLowerCase();
  const catalogProp = adminCatalogKeyMap[rawKey];
  if (!catalogProp) {
    return res.status(404).json({ error: "Catalogo no encontrado" });
  }

  const itemsPayload = Array.isArray(req.body?.items) ? req.body.items : null;
  if (!itemsPayload) {
    return res.status(400).json({ error: "items debe ser un arreglo" });
  }

  const current = normalizeAdminCatalogs(adminCatalogs);
  const source = [...(current[catalogProp] || [])];
  const candidate = uniqueCatalogItems(itemsPayload);

  if (source.length != candidate.length) {
    return res.status(400).json({ error: "La lista de orden debe contener exactamente las mismas entradas" });
  }

  const sourceSet = new Set(source);
  const sameItems = candidate.every((item) => sourceSet.has(item));
  if (!sameItems) {
    return res.status(400).json({ error: "La lista de orden contiene entradas invalidas" });
  }

  const merged = {
    ...current,
    [catalogProp]: candidate
  };

  adminCatalogs = saveAdminCatalogs(merged);
  adminCatalogs = applyAdminCatalogs(adminCatalogs);

  return res.json({
    ok: true,
    catalogKey: rawKey,
    catalogs: serializeAdminCatalogs()
  });
});

app.get("/api/admin/vehicle-accessories", (_req, res) => {
  return res.json({ accessories: [...adminVehicleAccessoriesCatalog] });
});

app.get("/api/admin/vehicles", (_req, res) => {
  return res.json({ vehicles: [...adminVehicles] });
});

app.post("/api/admin/vehicles", (req, res) => {
  const normalized = normalizeAdminVehicleRecord(req.body || {});
  if (!normalized) {
    return res.status(400).json({ error: "Datos de vehiculo invalidos. Revisa placa y categoria." });
  }

  const vehicleComplianceError = validateVehicleDocumentCompliance(normalized);
  if (vehicleComplianceError) {
    return res.status(400).json({ error: vehicleComplianceError });
  }

  const duplicate = adminVehicles.some((item) => item.plateNumber === normalized.plateNumber);
  if (duplicate) {
    return res.status(409).json({ error: "La placa ya existe en el registro." });
  }

  adminVehicles = saveAdminVehicles([normalized, ...adminVehicles]);
  return res.status(201).json({ ok: true, vehicle: normalized, vehicles: [...adminVehicles] });
});

app.put("/api/admin/vehicles/:id", (req, res) => {
  const id = String(req.params.id || "").trim();
  const current = adminVehicles.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Vehiculo no encontrado" });
  }

  const mergedPayload = {
    ...current,
    ...(req.body && typeof req.body === "object" ? req.body : {}),
    id,
    createdAt: current.createdAt
  };
  const normalized = normalizeAdminVehicleRecord(mergedPayload, { existingId: id });
  if (!normalized) {
    return res.status(400).json({ error: "Datos de vehiculo invalidos" });
  }

  const vehicleComplianceError = validateVehicleDocumentCompliance(normalized);
  if (vehicleComplianceError) {
    return res.status(400).json({ error: vehicleComplianceError });
  }

  const duplicate = adminVehicles.some((item) => item.id !== id && item.plateNumber === normalized.plateNumber);
  if (duplicate) {
    return res.status(409).json({ error: "La placa ya existe en otro vehiculo" });
  }

  adminVehicles = saveAdminVehicles(adminVehicles.map((item) => (item.id === id ? normalized : item)));
  return res.json({ ok: true, vehicle: normalized, vehicles: [...adminVehicles] });
});

app.patch("/api/admin/vehicles/:id/status", (req, res) => {
  const id = String(req.params.id || "").trim();
  const active = req.body?.active;
  if (typeof active !== "boolean") {
    return res.status(400).json({ error: "active debe ser boolean" });
  }

  const current = adminVehicles.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Vehiculo no encontrado" });
  }

  const normalized = normalizeAdminVehicleRecord({
    ...current,
    active
  }, { existingId: id });

  if (!normalized) {
    return res.status(400).json({ error: "No se pudo actualizar estado de vehiculo" });
  }

  adminVehicles = saveAdminVehicles(adminVehicles.map((item) => (item.id === id ? normalized : item)));
  return res.json({ ok: true, vehicle: normalized, vehicles: [...adminVehicles] });
});

app.patch("/api/admin/vehicles/:id/suspension", (req, res) => {
  const id = String(req.params.id || "").trim();
  const suspended = req.body?.suspended;
  const reason = String(req.body?.reason || "").trim().slice(0, 500);
  if (typeof suspended !== "boolean") {
    return res.status(400).json({ error: "suspended debe ser boolean" });
  }

  const current = adminVehicles.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Vehiculo no encontrado" });
  }

  const normalized = normalizeAdminVehicleRecord(
    {
      ...current,
      suspended,
      suspensionReason: reason,
      active: suspended ? false : current.active
    },
    { existingId: id }
  );

  if (!normalized) {
    return res.status(400).json({ error: "No se pudo actualizar suspension de vehiculo" });
  }

  adminVehicles = saveAdminVehicles(adminVehicles.map((item) => (item.id === id ? normalized : item)));
  appendAdminSanction({
    subjectType: "vehicle",
    subjectId: normalized.id,
    action: suspended ? "suspend" : "unsuspend",
    reason
  });
  return res.json({ ok: true, vehicle: normalized, vehicles: [...adminVehicles] });
});

app.delete("/api/admin/vehicles/:id", (req, res) => {
  const id = String(req.params.id || "").trim();
  const exists = adminVehicles.some((item) => item.id === id);
  if (!exists) {
    return res.status(404).json({ error: "Vehiculo no encontrado" });
  }

  adminVehicles = saveAdminVehicles(adminVehicles.filter((item) => item.id !== id));
  adminDrivers = saveAdminDrivers(
    adminDrivers.map((driver) => ({
      ...driver,
      assignedVehicleIds: Array.isArray(driver.assignedVehicleIds)
        ? driver.assignedVehicleIds.filter((vehicleId) => vehicleId !== id)
        : []
    }))
  );
  return res.json({ ok: true, vehicles: [...adminVehicles] });
});

app.get("/api/admin/driver-documents", (_req, res) => {
  return res.json({ documents: [...adminDriverDocumentKeys] });
});

app.get("/api/admin/driver-skills", (_req, res) => {
  return res.json({ skills: [...adminDriverSkillsCatalog] });
});

app.get("/api/admin/drivers/audit", (req, res) => {
  const driverId = String(req.query.driverId || "").trim();
  const limitRaw = Number(req.query.limit || 100);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(500, Math.trunc(limitRaw))) : 100;
  const filtered = driverId
    ? adminDriverAudit.filter((entry) => entry.driverId === driverId)
    : adminDriverAudit;
  return res.json({ audit: filtered.slice(0, limit) });
});

app.get("/api/admin/sanctions", (req, res) => {
  const subjectType = String(req.query.subjectType || "").trim().toLowerCase();
  const subjectId = String(req.query.subjectId || "").trim();
  const limit = Math.max(1, Math.min(500, Number(req.query.limit) || 150));

  const filtered = adminSanctions.filter((entry) => {
    if (subjectType && entry.subjectType !== subjectType) {
      return false;
    }
    if (subjectId && entry.subjectId !== subjectId) {
      return false;
    }
    return true;
  });

  return res.json({ sanctions: filtered.slice(0, limit) });
});

app.get("/api/admin/sanctions.csv", (req, res) => {
  const subjectType = String(req.query.subjectType || "").trim().toLowerCase();
  const subjectId = String(req.query.subjectId || "").trim();
  const limit = Math.max(1, Math.min(5000, Number(req.query.limit) || 1000));

  const filtered = adminSanctions.filter((entry) => {
    if (subjectType && entry.subjectType !== subjectType) {
      return false;
    }
    if (subjectId && entry.subjectId !== subjectId) {
      return false;
    }
    return true;
  }).slice(0, limit);

  const rows = [
    ["id", "subjectType", "subjectId", "action", "reason", "actor", "createdAt"],
    ...filtered.map((entry) => [
      entry.id,
      entry.subjectType,
      entry.subjectId,
      entry.action,
      entry.reason,
      entry.actor,
      entry.createdAt
    ])
  ];

  res.setHeader("Content-Type", "text/csv; charset=utf-8");
  res.setHeader("Content-Disposition", "attachment; filename=admin-sanctions.csv");
  return res.status(200).send(toCsvString(rows));
});

app.get("/api/admin/drivers", (_req, res) => {
  return res.json({ drivers: adminDrivers.map(adminDriverWithRating) });
});

app.get("/api/admin/drivers/:id/account-statement", (req, res) => {
  const driverId = String(req.params.id || "").trim();
  const driver = adminDrivers.find((item) => item.id === driverId) || drivers.find((item) => item.id === driverId);
  if (!driver) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const windowDays = Math.max(1, Math.min(365, Number(req.query.windowDays) || 30));
  const limit = Math.max(1, Math.min(2000, Number(req.query.limit) || 300));
  const statement = getDriverLedgerEntries(driverId, {
    from: req.query.from,
    to: req.query.to,
    windowDays,
    limit
  });

  return res.json({
    driverId,
    from: statement.from,
    to: statement.to,
    summary: summarizeDriverLedger(statement.entries),
    entries: statement.entries
  });
});

app.get("/api/admin/drivers/:id/account-statement.csv", (req, res) => {
  const driverId = String(req.params.id || "").trim();
  const driver = adminDrivers.find((item) => item.id === driverId) || drivers.find((item) => item.id === driverId);
  if (!driver) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const windowDays = Math.max(1, Math.min(365, Number(req.query.windowDays) || 30));
  const limit = Math.max(1, Math.min(5000, Number(req.query.limit) || 2000));
  const statement = getDriverLedgerEntries(driverId, {
    from: req.query.from,
    to: req.query.to,
    windowDays,
    limit
  });

  const rows = [
    ["id", "driverId", "rideId", "type", "amount", "currency", "description", "createdAt"],
    ...statement.entries.map((entry) => [
      entry.id,
      entry.driverId,
      entry.rideId || "",
      entry.type,
      Number(entry.amount || 0).toFixed(2),
      entry.currency,
      entry.description,
      entry.createdAt
    ])
  ];

  res.setHeader("Content-Type", "text/csv; charset=utf-8");
  res.setHeader("Content-Disposition", `attachment; filename=driver-account-${driverId}.csv`);
  return res.status(200).send(toCsvString(rows));
});

app.post("/api/admin/drivers/:id/payout", (req, res) => {
  const driverId = String(req.params.id || "").trim();
  const driver = adminDrivers.find((item) => item.id === driverId) || drivers.find((item) => item.id === driverId);
  if (!driver) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const amountValue = Number(req.body?.amount);
  const amount = Number.isFinite(amountValue) ? Number(amountValue.toFixed(2)) : NaN;
  const note = String(req.body?.note || "").trim().slice(0, 500);
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ error: "amount debe ser mayor a 0" });
  }

  const entry = appendDriverLedgerEntry({
    driverId,
    type: "payout",
    amount: -Math.abs(amount),
    description: note || "Pago/liquidacion registrada por admin"
  });

  if (!entry) {
    return res.status(400).json({ error: "No se pudo registrar el pago" });
  }

  return res.status(201).json({ ok: true, entry });
});

app.post("/api/admin/drivers/:id/adjustment", (req, res) => {
  const driverId = String(req.params.id || "").trim();
  const driver = adminDrivers.find((item) => item.id === driverId) || drivers.find((item) => item.id === driverId);
  if (!driver) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const kind = String(req.body?.kind || "").trim().toLowerCase();
  const allowedKinds = new Set(["credit", "debit"]);
  if (!allowedKinds.has(kind)) {
    return res.status(400).json({ error: "kind debe ser credit o debit" });
  }

  const amountValue = Number(req.body?.amount);
  const amount = Number.isFinite(amountValue) ? Number(amountValue.toFixed(2)) : NaN;
  const note = String(req.body?.note || "").trim().slice(0, 500);
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ error: "amount debe ser mayor a 0" });
  }

  const signedAmount = kind === "credit" ? Math.abs(amount) : -Math.abs(amount);
  const entry = appendDriverLedgerEntry({
    driverId,
    type: kind === "credit" ? "adjustment_credit" : "adjustment_debit",
    amount: signedAmount,
    description: note || (kind === "credit" ? "Ajuste a favor" : "Ajuste a cargo")
  });

  if (!entry) {
    return res.status(400).json({ error: "No se pudo registrar ajuste" });
  }

  return res.status(201).json({ ok: true, entry });
});

app.patch("/api/admin/drivers/:id/suspension", (req, res) => {
  const id = String(req.params.id || "").trim();
  const suspended = req.body?.suspended;
  const reason = String(req.body?.reason || "").trim().slice(0, 500);
  if (typeof suspended !== "boolean") {
    return res.status(400).json({ error: "suspended debe ser boolean" });
  }

  const current = adminDrivers.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const normalized = normalizeAdminDriverRecord(
    {
      ...current,
      suspended,
      suspensionReason: reason,
      active: suspended ? false : current.active
    },
    { existingId: id }
  );

  adminDrivers = saveAdminDrivers(adminDrivers.map((item) => (item.id === id ? normalized : item)));
  upsertRuntimeDriverFromAdmin(normalized);
  broadcastDrivers();
  appendAdminDriverAudit({
    driverId: normalized.id,
    action: "suspension",
    details: suspended ? `Suspendido: ${reason || "sin motivo"}` : "Suspension retirada"
  });
  appendAdminSanction({
    subjectType: "driver",
    subjectId: normalized.id,
    action: suspended ? "suspend" : "unsuspend",
    reason
  });

  return res.json({
    ok: true,
    driver: adminDriverWithRating(normalized),
    drivers: adminDrivers.map(adminDriverWithRating)
  });
});

app.get("/api/admin/customers", (_req, res) => {
  const list = adminCustomers.map((customer) => {
    applyCustomerRatingSummary(customer);
    return {
      ...customer,
      rating: customer.rating || "0.00",
      ratingCount: customer.ratingCount || 0
    };
  });
  return res.json({ customers: list });
});

app.patch("/api/admin/customers/:id/status", (req, res) => {
  const id = String(req.params.id || "").trim();
  const active = req.body?.active;
  if (typeof active !== "boolean") {
    return res.status(400).json({ error: "active debe ser boolean" });
  }

  const current = adminCustomers.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Cliente no encontrado" });
  }

  const normalized = normalizeCustomerRecord({ ...current, active }, { existingId: id });
  adminCustomers = saveAdminCustomers(adminCustomers.map((item) => (item.id === id ? normalized : item)));
  applyCustomerRatingSummary(normalized);
  return res.json({ ok: true, customer: normalized, customers: adminCustomers });
});

app.patch("/api/admin/customers/:id/suspension", (req, res) => {
  const id = String(req.params.id || "").trim();
  const suspended = req.body?.suspended;
  const reason = String(req.body?.reason || "").trim().slice(0, 500);
  if (typeof suspended !== "boolean") {
    return res.status(400).json({ error: "suspended debe ser boolean" });
  }

  const current = adminCustomers.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Cliente no encontrado" });
  }

  const normalized = normalizeCustomerRecord(
    {
      ...current,
      suspended,
      suspensionReason: reason,
      active: suspended ? false : current.active
    },
    { existingId: id }
  );

  adminCustomers = saveAdminCustomers(adminCustomers.map((item) => (item.id === id ? normalized : item)));
  applyCustomerRatingSummary(normalized);
  appendAdminSanction({
    subjectType: "customer",
    subjectId: normalized.id,
    action: suspended ? "suspend" : "unsuspend",
    reason
  });
  return res.json({ ok: true, customer: normalized, customers: adminCustomers });
});

app.get("/api/admin/incidents/catalog", (_req, res) => {
  return res.json({ categories: incidentCategoryCatalog });
});

app.get("/api/admin/incidents", (req, res) => {
  const subjectType = String(req.query.subjectType || "").trim().toLowerCase();
  const severity = String(req.query.severity || "").trim().toLowerCase();
  const status = String(req.query.status || "").trim().toLowerCase();
  const limit = Math.max(1, Math.min(500, Number(req.query.limit) || 150));

  const filtered = adminIncidents.filter((item) => {
    if (subjectType && item.subjectType !== subjectType) {
      return false;
    }
    if (severity && item.severity !== severity) {
      return false;
    }
    if (status && item.status !== status) {
      return false;
    }
    return true;
  });

  return res.json({ incidents: filtered.slice(0, limit) });
});

app.get("/api/admin/incidents.csv", (req, res) => {
  const subjectType = String(req.query.subjectType || "").trim().toLowerCase();
  const severity = String(req.query.severity || "").trim().toLowerCase();
  const status = String(req.query.status || "").trim().toLowerCase();
  const limit = Math.max(1, Math.min(5000, Number(req.query.limit) || 1000));

  const filtered = adminIncidents.filter((item) => {
    if (subjectType && item.subjectType !== subjectType) {
      return false;
    }
    if (severity && item.severity !== severity) {
      return false;
    }
    if (status && item.status !== status) {
      return false;
    }
    return true;
  }).slice(0, limit);

  const rows = [
    [
      "id",
      "subjectType",
      "subjectId",
      "category",
      "severity",
      "title",
      "details",
      "reportedBy",
      "rideId",
      "status",
      "createdAt"
    ],
    ...filtered.map((item) => [
      item.id,
      item.subjectType,
      item.subjectId,
      item.category,
      item.severity,
      item.title,
      item.details,
      item.reportedBy,
      item.rideId,
      item.status,
      item.createdAt
    ])
  ];

  res.setHeader("Content-Type", "text/csv; charset=utf-8");
  res.setHeader("Content-Disposition", "attachment; filename=admin-incidents.csv");
  return res.status(200).send(toCsvString(rows));
});

app.post("/api/admin/incidents", (req, res) => {
  const record = appendAdminIncident(req.body || {});
  if (!record) {
    return res.status(400).json({ error: "Datos de incidencia invalidos" });
  }

  return res.status(201).json({ ok: true, incident: record, incidents: adminIncidents });
});

app.patch("/api/admin/incidents/:id/status", (req, res) => {
  const id = String(req.params.id || "").trim();
  const status = String(req.body?.status || "").trim().toLowerCase();
  const current = adminIncidents.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Incidencia no encontrada" });
  }

  const allowed = new Set(["open", "in_review", "resolved", "dismissed"]);
  if (!allowed.has(status)) {
    return res.status(400).json({ error: "status invalido" });
  }

  const updated = normalizeIncidentRecord({ ...current, status });
  adminIncidents = saveAdminIncidents(adminIncidents.map((item) => (item.id === id ? updated : item)));
  return res.json({ ok: true, incident: updated });
});

app.post("/api/admin/drivers", (req, res) => {
  const normalized = normalizeAdminDriverRecord(req.body || {});
  if (!normalized) {
    return res.status(400).json({ error: "Datos de chofer invalidos. Revisa nombre, telefono, categoria y licencia." });
  }

  const driverComplianceError = validateDriverDocumentCompliance(normalized);
  if (driverComplianceError) {
    return res.status(400).json({ error: driverComplianceError });
  }

  const duplicatePhone = adminDrivers.some((item) => item.phone === normalized.phone);
  if (duplicatePhone) {
    return res.status(409).json({ error: "Ya existe un chofer con ese telefono." });
  }

  adminDrivers = saveAdminDrivers([normalized, ...adminDrivers]);
  upsertRuntimeDriverFromAdmin(normalized);
  broadcastDrivers();
  appendAdminDriverAudit({
    driverId: normalized.id,
    action: "create",
    details: `Alta de chofer ${normalized.firstName} ${normalized.lastName}`
  });
  return res.status(201).json({
    ok: true,
    driver: adminDriverWithRating(normalized),
    drivers: adminDrivers.map(adminDriverWithRating)
  });
});

app.put("/api/admin/drivers/:id", (req, res) => {
  const id = String(req.params.id || "").trim();
  const current = adminDrivers.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const mergedPayload = {
    ...current,
    ...(req.body && typeof req.body === "object" ? req.body : {}),
    id,
    createdAt: current.createdAt
  };
  const normalized = normalizeAdminDriverRecord(mergedPayload, { existingId: id });
  if (!normalized) {
    return res.status(400).json({ error: "Datos de chofer invalidos" });
  }

  const driverComplianceError = validateDriverDocumentCompliance(normalized);
  if (driverComplianceError) {
    return res.status(400).json({ error: driverComplianceError });
  }

  const duplicatePhone = adminDrivers.some((item) => item.id !== id && item.phone === normalized.phone);
  if (duplicatePhone) {
    return res.status(409).json({ error: "Ese telefono ya esta registrado en otro chofer." });
  }

  adminDrivers = saveAdminDrivers(adminDrivers.map((item) => (item.id === id ? normalized : item)));
  upsertRuntimeDriverFromAdmin(normalized);
  broadcastDrivers();
  appendAdminDriverAudit({
    driverId: normalized.id,
    action: "update",
    details: `Actualizacion de chofer ${normalized.firstName} ${normalized.lastName}`
  });
  return res.json({
    ok: true,
    driver: adminDriverWithRating(normalized),
    drivers: adminDrivers.map(adminDriverWithRating)
  });
});

app.patch("/api/admin/drivers/:id/status", (req, res) => {
  const id = String(req.params.id || "").trim();
  const active = req.body?.active;
  if (typeof active !== "boolean") {
    return res.status(400).json({ error: "active debe ser boolean" });
  }

  const current = adminDrivers.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const normalized = normalizeAdminDriverRecord({ ...current, active }, { existingId: id });
  if (!normalized) {
    return res.status(400).json({ error: "No se pudo actualizar estatus del chofer" });
  }

  adminDrivers = saveAdminDrivers(adminDrivers.map((item) => (item.id === id ? normalized : item)));
  upsertRuntimeDriverFromAdmin(normalized);
  broadcastDrivers();
  appendAdminDriverAudit({
    driverId: normalized.id,
    action: "status",
    details: `Estatus ${active ? "activo" : "inactivo"}`
  });
  return res.json({
    ok: true,
    driver: adminDriverWithRating(normalized),
    drivers: adminDrivers.map(adminDriverWithRating)
  });
});

app.patch("/api/admin/drivers/:id/availability", (req, res) => {
  const id = String(req.params.id || "").trim();
  const available = req.body?.available;
  if (typeof available !== "boolean") {
    return res.status(400).json({ error: "available debe ser boolean" });
  }

  const current = adminDrivers.find((item) => item.id === id);
  if (!current) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const normalized = normalizeAdminDriverRecord({ ...current, available }, { existingId: id });
  if (!normalized) {
    return res.status(400).json({ error: "No se pudo actualizar disponibilidad" });
  }

  adminDrivers = saveAdminDrivers(adminDrivers.map((item) => (item.id === id ? normalized : item)));
  upsertRuntimeDriverFromAdmin(normalized);
  broadcastDrivers();
  appendAdminDriverAudit({
    driverId: normalized.id,
    action: "availability",
    details: `Disponibilidad ${available ? "disponible" : "no disponible"}`
  });
  return res.json({
    ok: true,
    driver: adminDriverWithRating(normalized),
    drivers: adminDrivers.map(adminDriverWithRating)
  });
});

app.delete("/api/admin/drivers/:id", (req, res) => {
  const id = String(req.params.id || "").trim();
  const exists = adminDrivers.some((item) => item.id === id);
  if (!exists) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  appendAdminDriverAudit({
    driverId: id,
    action: "delete",
    details: "Baja de chofer"
  });
  adminDrivers = saveAdminDrivers(adminDrivers.filter((item) => item.id !== id));
  removeRuntimeDriverById(id);
  broadcastDrivers();
  return res.json({ ok: true, drivers: adminDrivers.map(adminDriverWithRating) });
});

app.put("/api/admin/pricing-config", (req, res) => {
  const payload = req.body || {};
  const validationErrors = [];

  const numericField = (name, minValue) => {
    const value = Number(payload[name]);
    if (!Number.isFinite(value) || value < minValue) {
      validationErrors.push(`${name} inválido`);
      return null;
    }
    return value;
  };

  const foraneoThresholdKm = numericField("foraneoThresholdKm", 0);
  const includedKmInStartFare = numericField("includedKmInStartFare", 0);
  const foraneoMultiplier = numericField("foraneoMultiplier", 1);
  const defaultLoadingMinutes = numericField("defaultLoadingMinutes", 0);
  const defaultTransferMinutes = numericField("defaultTransferMinutes", 0);
  const defaultUnloadingMinutes = numericField("defaultUnloadingMinutes", 0);
  const loadPersonnelUnitCost = numericField("loadPersonnelUnitCost", 0);
  const unloadPersonnelUnitCost = numericField("unloadPersonnelUnitCost", 0);
  const driverNetDailyTarget = numericField("driverNetDailyTarget", 0);
  const driverWorkHoursPerDay = numericField("driverWorkHoursPerDay", 1);
  const fuelPricePerLiter = numericField("fuelPricePerLiter", 0);
  const appCommissionRatePct = numericField("appCommissionRatePct", 0);
  const vatRatePct = numericField("vatRatePct", 0);
  const fiscalReserveRatePct = numericField("fiscalReserveRatePct", 0);
  const maneuverPlatformMarginRate = numericField("maneuverPlatformMarginRate", 0);
  const marketplaceVisibleCategoriesRaw = Array.isArray(payload.marketplaceVisibleCategories)
    ? payload.marketplaceVisibleCategories
    : [];
  const marketplaceVisibleCategories = [...new Set(
    marketplaceVisibleCategoriesRaw
      .map((value) => String(value || "").trim())
      .filter((value) => Boolean(vehicleCategories[value]))
  )];
  if (marketplaceVisibleCategories.length === 0) {
    marketplaceVisibleCategories.push("specialized_1t");
  }
  const driverToPickupDistanceRatio = numericField("driverToPickupDistanceRatio", 0);

  const categoriesPayload = payload.categories && typeof payload.categories === "object" ? payload.categories : null;
  if (!categoriesPayload) {
    validationErrors.push("categories inválido");
  }

  const normalizedCategories = {};
  Object.keys(defaultAdminPricingConfig.categories).forEach((categoryKey) => {
    const rawCategory = categoriesPayload && categoriesPayload[categoryKey];
    if (!rawCategory || typeof rawCategory !== "object") {
      validationErrors.push(`categories.${categoryKey} inválido`);
      return;
    }

    const startFare = Number(rawCategory.startFare);
    const extraKmRate = Number(rawCategory.extraKmRate);
    const operationalPerMinRate = Number(rawCategory.operationalPerMinRate);
    const rawOperatingProfile =
      rawCategory.operatingProfile && typeof rawCategory.operatingProfile === "object"
        ? rawCategory.operatingProfile
        : null;

    if (!Number.isFinite(startFare) || startFare < 0) {
      validationErrors.push(`categories.${categoryKey}.startFare inválido`);
    }
    if (!Number.isFinite(extraKmRate) || extraKmRate < 0) {
      validationErrors.push(`categories.${categoryKey}.extraKmRate inválido`);
    }
    if (!Number.isFinite(operationalPerMinRate) || operationalPerMinRate < 0) {
      validationErrors.push(`categories.${categoryKey}.operationalPerMinRate inválido`);
    }

    if (!rawOperatingProfile) {
      validationErrors.push(`categories.${categoryKey}.operatingProfile inválido`);
    }

    const fuelEfficiencyKmPerLiter = Number(rawOperatingProfile?.fuelEfficiencyKmPerLiter);
    const avgSpeedKmhNoTraffic = Number(rawOperatingProfile?.avgSpeedKmhNoTraffic);
    const maintenancePerKm = Number(rawOperatingProfile?.maintenancePerKm);
    const depreciationPerKm = Number(rawOperatingProfile?.depreciationPerKm);
    const insurancePerKm = Number(rawOperatingProfile?.insurancePerKm);
    const permitsPerKm = Number(rawOperatingProfile?.permitsPerKm);

    if (!Number.isFinite(fuelEfficiencyKmPerLiter) || fuelEfficiencyKmPerLiter <= 0) {
      validationErrors.push(`categories.${categoryKey}.operatingProfile.fuelEfficiencyKmPerLiter inválido`);
    }
    if (!Number.isFinite(avgSpeedKmhNoTraffic) || avgSpeedKmhNoTraffic <= 0) {
      validationErrors.push(`categories.${categoryKey}.operatingProfile.avgSpeedKmhNoTraffic inválido`);
    }
    if (!Number.isFinite(maintenancePerKm) || maintenancePerKm < 0) {
      validationErrors.push(`categories.${categoryKey}.operatingProfile.maintenancePerKm inválido`);
    }
    if (!Number.isFinite(depreciationPerKm) || depreciationPerKm < 0) {
      validationErrors.push(`categories.${categoryKey}.operatingProfile.depreciationPerKm inválido`);
    }
    if (!Number.isFinite(insurancePerKm) || insurancePerKm < 0) {
      validationErrors.push(`categories.${categoryKey}.operatingProfile.insurancePerKm inválido`);
    }
    if (!Number.isFinite(permitsPerKm) || permitsPerKm < 0) {
      validationErrors.push(`categories.${categoryKey}.operatingProfile.permitsPerKm inválido`);
    }

    normalizedCategories[categoryKey] = {
      startFare: Number((Number.isFinite(startFare) ? startFare : 0).toFixed(2)),
      extraKmRate: Number((Number.isFinite(extraKmRate) ? extraKmRate : 0).toFixed(2)),
      operationalPerMinRate: Number((Number.isFinite(operationalPerMinRate) ? operationalPerMinRate : 0).toFixed(2)),
      operatingProfile: {
        fuelEfficiencyKmPerLiter: Number((Number.isFinite(fuelEfficiencyKmPerLiter) ? fuelEfficiencyKmPerLiter : 1).toFixed(2)),
        avgSpeedKmhNoTraffic: Number((Number.isFinite(avgSpeedKmhNoTraffic) ? avgSpeedKmhNoTraffic : 5).toFixed(2)),
        maintenancePerKm: Number((Number.isFinite(maintenancePerKm) ? maintenancePerKm : 0).toFixed(2)),
        depreciationPerKm: Number((Number.isFinite(depreciationPerKm) ? depreciationPerKm : 0).toFixed(2)),
        insurancePerKm: Number((Number.isFinite(insurancePerKm) ? insurancePerKm : 0).toFixed(2)),
        permitsPerKm: Number((Number.isFinite(permitsPerKm) ? permitsPerKm : 0).toFixed(2))
      }
    };
  });

  if (validationErrors.length) {
    return res.status(400).json({ error: validationErrors.join(", ") });
  }

  adminPricingConfig = {
    ...adminPricingConfig,
    foraneoThresholdKm: Number(foraneoThresholdKm.toFixed(2)),
    includedKmInStartFare: Number(includedKmInStartFare.toFixed(2)),
    foraneoMultiplier: Number(foraneoMultiplier.toFixed(2)),
    defaultLoadingMinutes: Number(defaultLoadingMinutes.toFixed(2)),
    defaultTransferMinutes: Number(defaultTransferMinutes.toFixed(2)),
    defaultUnloadingMinutes: Number(defaultUnloadingMinutes.toFixed(2)),
    loadPersonnelUnitCost: Number(loadPersonnelUnitCost.toFixed(2)),
    unloadPersonnelUnitCost: Number(unloadPersonnelUnitCost.toFixed(2)),
    driverNetDailyTarget: Number(driverNetDailyTarget.toFixed(2)),
    driverWorkHoursPerDay: Number(driverWorkHoursPerDay.toFixed(2)),
    fuelPricePerLiter: Number(fuelPricePerLiter.toFixed(2)),
    appCommissionRatePct: Number(appCommissionRatePct.toFixed(2)),
    vatRatePct: Number(vatRatePct.toFixed(2)),
    fiscalReserveRatePct: Number(fiscalReserveRatePct.toFixed(2)),
    maneuverPlatformMarginRate: Number(maneuverPlatformMarginRate.toFixed(4)),
    marketplaceVisibleCategories,
    driverToPickupDistanceRatio: Number(driverToPickupDistanceRatio.toFixed(4)),
    categories: normalizedCategories
  };

  adminPricingConfig = applyAdminPricingConfig(adminPricingConfig);
  adminPricingConfig = saveAdminPricingConfig(adminPricingConfig);

  return res.json({
    ok: true,
    config: {
      ...adminPricingConfig,
      categories: { ...adminPricingConfig.categories },
      municipalities: [...tripRules.municipalities]
    }
  });
});

app.get("/api/quote", (req, res) => {
  const distance = Number(req.query.distance || randomTripDistance());
  const category = String(req.query.category || "pickup_mini");
  const pickup = String(req.query.pickup || "");
  const dropoff = String(req.query.dropoff || "");
  const inferredRouteType = resolveRouteType(pickup, dropoff, distance);
  const routeType = String(req.query.routeType || inferredRouteType);
  const service = String(req.query.service || getServiceKeyByRouteType(category, routeType));
  const loadingMinutes = Math.max(0, Number(req.query.loadingMinutes ?? adminPricingConfig.defaultLoadingMinutes) || 0);
  const transferMinutes = Math.max(0, Number(req.query.transferMinutes ?? adminPricingConfig.defaultTransferMinutes) || 0);
  const unloadingMinutes = Math.max(0, Number(req.query.unloadingMinutes ?? adminPricingConfig.defaultUnloadingMinutes) || 0);
  const hasWaitOverride = req.query.waitMinutes !== undefined && String(req.query.waitMinutes).trim() !== "";
  const operationalMinutes = hasWaitOverride
    ? Math.max(0, Number(req.query.waitMinutes) || 0)
    : Number((loadingMinutes + transferMinutes + unloadingMinutes).toFixed(2));
  const maneuverInfo = resolveOptionalManeuverCharge({
    selectedValue: req.query.maneuverSelected ?? req.query.includeLoadingUnloadingManeuver,
    distanceMetersValue: req.query.maneuverDistanceMeters ?? req.query.loadingUnloadingDistanceMeters,
    loaderPayPerTrip: DEFAULT_MANEUVER_LOADER_PAY_PER_TRIP,
    platformMarginRate: adminPricingConfig.maneuverPlatformMarginRate
  });
  if (!maneuverInfo.valid) {
    return res.status(400).json({ error: maneuverInfo.error });
  }
  const loadPersonnelCount = 0;
  const unloadPersonnelCount = 0;
  const personnelSurcharge = Number((maneuverInfo.surcharge || 0).toFixed(2));
  const rawDriverToPickupDistance =
    req.query.driverToPickupDistanceKm !== undefined
      ? Number(req.query.driverToPickupDistanceKm)
      : null;
  const driverToPickupDistanceKm = Number.isFinite(rawDriverToPickupDistance)
    ? Math.max(0, Number(rawDriverToPickupDistance) || 0)
    : null;

  const services = serviceCatalog[category];
  if (!services || !services[service]) {
    return res.status(400).json({ error: "Categoría o servicio inválido" });
  }

  const fareResult = buildFareBreakdown({
    distance,
    categoryKey: category,
    serviceKey: service,
    waitMinutes: operationalMinutes,
    routeType,
    personnelSurcharge,
    driverToPickupDistanceKm
  });
  const fareEstimate = fareResult.fareEstimate;
  const rateCard = categoryRateCard[category] || categoryRateCard.pickup_mini;
  const includedKm = Math.max(0, Number(tripRules.includedKmInStartFare) || 0);
  const billableDistance = Math.max(0, distance - includedKm);

  return res.json({
    category,
    service,
    routeType,
    inferredRouteType,
    pickup,
    dropoff,
    distance,
    billableDistance,
    includedKmInStartFare: includedKm,
    waitMinutes: operationalMinutes,
    loadingMinutes,
    transferMinutes,
    unloadingMinutes,
    operationalMinutes,
    loadPersonnelCount,
    unloadPersonnelCount,
    maneuverSelected: maneuverInfo.selected,
    maneuverDistanceMeters: maneuverInfo.distanceMeters,
    maneuverEligible: maneuverInfo.eligible,
    maneuverMaxDistanceMeters: maneuverInfo.maxDistanceMeters,
    maneuverLoaderPayPerTrip: maneuverInfo.loaderPayPerTrip,
    maneuverPlatformMarginRate: maneuverInfo.platformMarginRate,
    maneuverPlatformMarginAmount: maneuverInfo.platformMarginAmount,
    maneuverSurchargePerTrip: maneuverInfo.chargeToCustomerPerTrip,
    maneuverSurcharge: personnelSurcharge,
    loadPersonnelUnitCost: adminPricingConfig.loadPersonnelUnitCost,
    unloadPersonnelUnitCost: adminPricingConfig.unloadPersonnelUnitCost,
    personnelSurcharge,
    fareEstimate,
    driverToPickupDistanceKm:
      fareResult.breakdown?.distanceAB ?? driverToPickupDistanceKm,
    costBreakdown: fareResult.breakdown,
    startFare: rateCard.startFare,
    perKmRate: rateCard.perKm,
    waitPerMinRate: rateCard.waitPerMin,
    currency: "MXN"
  });
});

app.post("/api/rides", (req, res) => {
  const {
    pickup,
    dropoff,
    category,
    service,
    pickupPoint,
    distance,
    scheduledAt,
    requestType,
    customer,
    notificationPreferences,
    maneuverSelected,
    maneuverDistanceMeters
  } = req.body || {};
  const requestedDistance = Math.max(0, Number(distance) || 0);
  const tripDistanceKm = requestedDistance || randomTripDistance();
  const inferredRouteType = resolveRouteType(pickup, dropoff, tripDistanceKm);
  const inferredService = getServiceKeyByRouteType(category, inferredRouteType);
  const effectiveService = serviceCatalog[category] && serviceCatalog[category][inferredService] ? inferredService : service;
  const normalizedPickupPoint = pickupPoint && Number.isFinite(Number(pickupPoint.lat)) && Number.isFinite(Number(pickupPoint.lng))
    ? { lat: Number(pickupPoint.lat), lng: Number(pickupPoint.lng) }
    : cityCenter;

  let normalizedScheduledAt = null;
  if (scheduledAt !== undefined && String(scheduledAt).trim() !== "") {
    const parsed = new Date(String(scheduledAt));
    if (Number.isNaN(parsed.getTime())) {
      return res.status(400).json({ error: "scheduledAt inválido. Usa formato ISO8601" });
    }

    if (parsed.getTime() <= Date.now()) {
      return res.status(400).json({ error: "scheduledAt debe ser una fecha futura" });
    }

    normalizedScheduledAt = parsed.toISOString();
  }

  const normalizedRequestType = normalizeRideRequestType(requestType, {
    hasScheduledAt: Boolean(normalizedScheduledAt)
  });
  if (normalizedRequestType === "scheduled" && !normalizedScheduledAt) {
    return res.status(400).json({
      error: "Para programar debes indicar fecha y hora (scheduledAt)."
    });
  }

  const normalizedNotificationPreferences = {
    whatsapp: notificationPreferences?.whatsapp === true,
    sms: notificationPreferences?.sms === true
  };
  const maneuverInfo = resolveOptionalManeuverCharge({
    selectedValue: maneuverSelected,
    distanceMetersValue: maneuverDistanceMeters,
    loaderPayPerTrip: DEFAULT_MANEUVER_LOADER_PAY_PER_TRIP,
    platformMarginRate: adminPricingConfig.maneuverPlatformMarginRate
  });
  if (!maneuverInfo.valid) {
    return res.status(400).json({ error: maneuverInfo.error });
  }

  if (!pickup || !dropoff || !serviceCatalog[category] || !serviceCatalog[category][effectiveService]) {
    return res.status(400).json({
      error: "Debes enviar pickup, dropoff, categoría y servicio válidos"
    });
  }

  const customerPayload = customer && typeof customer === "object" ? customer : {};
  const auth = getAuthContext(req);
  const authenticatedCustomerId = auth.authenticated && auth.role === "customer"
    ? String(auth.userId || "").trim()
    : "";
  const customerRecord = ensureCustomerRecord({
    id: authenticatedCustomerId || customerPayload.id,
    fullName: customerPayload.fullName || customerPayload.name,
    phone: customerPayload.phone
  });

  const ride = {
    id: uuidv4(),
    pickup,
    dropoff,
    category,
    service: effectiveService,
    routeType: inferredRouteType,
    requestedAt: new Date().toISOString(),
    scheduledAt: normalizedScheduledAt,
    status: normalizedScheduledAt ? "scheduled" : "searching",
    requestType: normalizedRequestType,
    assignmentState: normalizedScheduledAt ? "scheduled" : "searching",
    tripDistanceKm,
    fareEstimate: 0,
    maneuverSelected: maneuverInfo.selected,
    maneuverDistanceMeters: maneuverInfo.distanceMeters,
    maneuverSurcharge: maneuverInfo.surcharge,
    etaMin: null,
    driver: null,
    customer: serializeRideCustomer(customerRecord),
    riderRating: null,
    driverRatedCustomer: false,
    pickupPoint: normalizedPickupPoint,
    timeline: [],
    progress: 0
  };

  ride.fareEstimate = estimateFare(
    ride.tripDistanceKm,
    ride.category,
    ride.service,
    0,
    ride.routeType,
    ride.maneuverSurcharge,
    null
  );
  appendTimeline(ride, buildRideRequestLabel(normalizedRequestType, normalizedScheduledAt));
  appendTimeline(ride, "Buscando conductor en tu categoría");
  if (ride.maneuverSelected) {
    appendTimeline(
      ride,
      `Incluye maniobra de carga/descarga (+MXN ${Number(ride.maneuverSurcharge || 0).toFixed(2)})`
    );
  }

  rides.set(ride.id, ride);
  broadcastRide(ride);

  if (!normalizedScheduledAt) {
    setTimeout(() => {
      const current = rides.get(ride.id);
      if (!current || current.driver?.id || current.status !== "searching") {
        return;
      }
      markRideAsPendingDriver(current);
      notifyOfflineDrivers(current, normalizedNotificationPreferences).catch(() => {});
    }, DRIVER_OFFER_PENDING_DELAY_MS);
  }

  return res.status(201).json(serializeRide(ride));
});

app.get("/api/rides/:id", (req, res) => {
  const ride = rides.get(req.params.id);
  if (!ride) {
    return res.status(404).json({ error: "Solicitud de carga no encontrada" });
  }

  if (AUTH_ENFORCE_ROLES) {
    const auth = getAuthContext(req);
    if (!auth.authenticated) {
      return res.status(401).json({ error: "Autenticacion requerida" });
    }

    if (!isAdminAuth(req)) {
      if (auth.role === "driver") {
        if (!ride.driver?.id || ride.driver.id !== auth.userId) {
          return res.status(403).json({ error: "Solo el chofer asignado puede consultar este viaje" });
        }
      } else if (auth.role === "customer") {
        if (!ride.customer?.id || ride.customer.id !== auth.userId) {
          return res.status(403).json({ error: "Solo el cliente del viaje puede consultarlo" });
        }
      } else {
        return res.status(403).json({ error: "Permisos insuficientes" });
      }
    }
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

  if (!enforceSelfOrAdmin(req, res, { role: "customer", actorId: ride.customer?.id, actorLabel: "cliente" })) {
    return;
  }

  ride.status = "cancelled";
  ride.assignmentState = "cancelled";
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

// Eliminar registro de viaje (solo cancelados/completados)
app.delete("/api/rides/:id", (req, res) => {
  const ride = rides.get(req.params.id);

  if (!ride) {
    return res.status(404).json({ error: "Solicitud de carga no encontrada" });
  }

  if (!["cancelled", "completed"].includes(ride.status)) {
    return res.status(409).json({ error: "Solo puedes eliminar viajes cancelados o completados" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "customer", actorId: ride.customer?.id, actorLabel: "cliente" })) {
    return;
  }

  rides.delete(req.params.id);
  return res.json({ success: true, id: req.params.id });
});

// Modo prueba: simula que un chofer acepta el primer viaje en búsqueda
app.post("/api/test/simulate-driver", (req, res) => {
  // Solo permitido en modo no-producción o por admin
  if (process.env.NODE_ENV === "production" && !isAdminAuth(req)) {
    return res.status(403).json({ error: "Modo prueba solo disponible para administradores en producción" });
  }

  const targetRideId = String(req.body?.rideId || "").trim();

  // Buscar primer viaje disponible
  const candidate = targetRideId
    ? rides.get(targetRideId)
    : [...rides.values()].find((r) => ["searching", "pending_driver"].includes(r.status));

  if (!candidate) {
    return res.status(404).json({ error: "No hay solicitudes de carga en espera" });
  }

  if (!["searching", "pending_driver"].includes(candidate.status)) {
    return res.status(409).json({ error: "El viaje seleccionado no está en estado de búsqueda" });
  }

  // Buscar o crear chofer de prueba con la categoría correcta
  let testDriver = drivers.find((d) => d.id === "TEST-DRIVER-001" && d.available);
  if (!testDriver) {
    testDriver = drivers.find((d) => d.category === candidate.category && d.available);
  }
  if (!testDriver) {
    // Crear chofer simulado temporal
    const fakeDriver = {
      id: `TEST-DRV-${Date.now()}`,
      name: "Chofer Demo (Prueba)",
      category: candidate.category,
      available: false,
      rating: 4.8,
      ratingCount: 12,
      completedRides: 34,
      vehicle: { plate: "DEMO-001", model: "Vehículo Demo", color: "Azul" },
      lat: (candidate.pickupPoint?.lat ?? 25.6866) + (Math.random() - 0.5) * 0.02,
      lng: (candidate.pickupPoint?.lng ?? -100.3161) + (Math.random() - 0.5) * 0.02,
      _isTestDriver: true,
    };
    drivers.push(fakeDriver);
    testDriver = fakeDriver;
  }

  testDriver.available = false;
  candidate.driver = {
    id: testDriver.id,
    name: testDriver.name,
    rating: testDriver.rating,
    ratingCount: testDriver.ratingCount || 0,
    vehicle: testDriver.vehicle,
    completedRides: testDriver.completedRides,
  };
  candidate.status = "accepted";
  candidate.assignmentState = "assigned";
  candidate.progress = Math.max(candidate.progress, 0.08);
  candidate.etaMin = etaMinutes(testDriver, candidate.pickupPoint || cityCenter);
  appendTimeline(candidate, `[DEMO] Conductor acepto el viaje: ${testDriver.name}`);

  broadcastRide(candidate);
  broadcastDrivers();

  return res.json({
    success: true,
    ride: serializeRide(candidate),
    driver: { id: testDriver.id, name: testDriver.name },
  });
});

app.post("/api/driver/devices/register", (req, res) => {
  const driverId = String(req.body?.driverId || "").trim();
  const token = String(req.body?.token || "").trim();
  const platform = String(req.body?.platform || "mobile").trim().toLowerCase();
  const appState = String(req.body?.appState || "unknown").trim().toLowerCase();

  if (!driverId) {
    return res.status(400).json({ error: "driverId es requerido" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "driver", actorId: driverId, actorLabel: "chofer" })) {
    return;
  }

  if (!token) {
    return res.status(400).json({ error: "token es requerido" });
  }

  const driver = drivers.find((item) => item.id === driverId) || adminDrivers.find((item) => item.id === driverId);
  if (!driver) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const saved = upsertDriverNotificationDevice({
    driverId,
    token,
    platform,
    appState,
    active: true
  });

  if (!saved) {
    return res.status(400).json({ error: "No se pudo registrar dispositivo" });
  }

  return res.status(201).json({ ok: true, device: saved });
});

app.get("/api/driver/account-statement", (req, res) => {
  const driverId = String(req.query.driverId || "").trim();
  if (!driverId) {
    return res.status(400).json({ error: "driverId es requerido" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "driver", actorId: driverId, actorLabel: "chofer" })) {
    return;
  }

  const driver = drivers.find((item) => item.id === driverId) || adminDrivers.find((item) => item.id === driverId);
  if (!driver) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const windowDays = Math.max(1, Math.min(365, Number(req.query.windowDays) || 30));
  const limit = Math.max(1, Math.min(2000, Number(req.query.limit) || 300));
  const statement = getDriverLedgerEntries(driverId, {
    from: req.query.from,
    to: req.query.to,
    windowDays,
    limit
  });

  return res.json({
    driverId,
    from: statement.from,
    to: statement.to,
    summary: summarizeDriverLedger(statement.entries),
    entries: statement.entries
  });
});

app.get("/api/driver/account-statement.csv", (req, res) => {
  const driverId = String(req.query.driverId || "").trim();
  if (!driverId) {
    return res.status(400).json({ error: "driverId es requerido" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "driver", actorId: driverId, actorLabel: "chofer" })) {
    return;
  }

  const driver = drivers.find((item) => item.id === driverId) || adminDrivers.find((item) => item.id === driverId);
  if (!driver) {
    return res.status(404).json({ error: "Chofer no encontrado" });
  }

  const windowDays = Math.max(1, Math.min(365, Number(req.query.windowDays) || 30));
  const limit = Math.max(1, Math.min(5000, Number(req.query.limit) || 2000));
  const statement = getDriverLedgerEntries(driverId, {
    from: req.query.from,
    to: req.query.to,
    windowDays,
    limit
  });

  const rows = [
    ["id", "driverId", "rideId", "type", "amount", "currency", "description", "createdAt"],
    ...statement.entries.map((entry) => [
      entry.id,
      entry.driverId,
      entry.rideId || "",
      entry.type,
      Number(entry.amount || 0).toFixed(2),
      entry.currency,
      entry.description,
      entry.createdAt
    ])
  ];

  res.setHeader("Content-Type", "text/csv; charset=utf-8");
  res.setHeader("Content-Disposition", `attachment; filename=driver-account-${driverId}.csv`);
  return res.status(200).send(toCsvString(rows));
});

app.get("/api/driver/rides", (req, res) => {
  const driverId = String(req.query.driverId || "").trim();
  const activeOnly = String(req.query.active || "") === "1";
  const requestedWindowHours = Number(req.query.scheduledWindowHours);
  const scheduledWindowHours = Number.isFinite(requestedWindowHours)
    ? Math.max(1, requestedWindowHours)
    : DEFAULT_SCHEDULED_VISIBILITY_WINDOW_HOURS;
  const nowMs = Date.now();
  const scheduledWindowEndMs = nowMs + scheduledWindowHours * 60 * 60 * 1000;
  const activeStatuses = new Set(["scheduled", "searching", "pending_driver", "accepted", "driver_arriving", "in_progress"]);
  const selectedDriver = driverId ? drivers.find((item) => item.id === driverId) : null;

  if (driverId && !enforceSelfOrAdmin(req, res, { role: "driver", actorId: driverId, actorLabel: "chofer" })) {
    return;
  }

  const list = [...rides.values()]
    .filter((ride) => {
      if (ride.status === "scheduled") {
        const scheduledMs = new Date(ride.scheduledAt || "").getTime();
        const isWithinWindow = Number.isFinite(scheduledMs) && scheduledMs >= nowMs && scheduledMs <= scheduledWindowEndMs;
        if (!isWithinWindow) {
          return false;
        }
      }

      if (driverId) {
        if (ride.driver?.id && ride.driver.id !== driverId) {
          return false;
        }

        if (!ride.driver?.id) {
          if (!selectedDriver) {
            return false;
          }

          const isOffer = ride.status === "searching" || ride.status === "scheduled" || ride.status === "pending_driver";
          if (!isOffer || ride.category !== selectedDriver.category) {
            return false;
          }
        }
      }

      if (activeOnly && !activeStatuses.has(ride.status)) {
        return false;
      }

      return true;
    })
    .sort((a, b) => {
      const aTime = new Date(a.scheduledAt || a.requestedAt).getTime();
      const bTime = new Date(b.scheduledAt || b.requestedAt).getTime();
      return bTime - aTime;
    })
    .map(serializeRide);

  return res.json(list);
});

app.post("/api/driver/rides/:id/status", (req, res) => {
  const ride = rides.get(req.params.id);
  const status = String(req.body?.status || "").trim();
  const driverId = String(req.body?.driverId || "").trim();
  const allowed = new Set(["accepted", "driver_arriving", "in_progress", "completed", "cancelled"]);

  if (!ride) {
    return res.status(404).json({ error: "Solicitud de carga no encontrada" });
  }

  if (!allowed.has(status)) {
    return res.status(400).json({ error: "status inválido" });
  }

  if (!driverId) {
    return res.status(400).json({ error: "driverId es requerido" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "driver", actorId: driverId, actorLabel: "chofer" })) {
    return;
  }

  if (["completed", "cancelled"].includes(ride.status)) {
    return res.status(409).json({ error: "No se puede actualizar en este estado" });
  }

  if (status === "accepted" && !["searching", "scheduled", "pending_driver", "accepted"].includes(ride.status)) {
    return res.status(409).json({ error: "Este viaje no se encuentra en etapa de asignacion" });
  }

  if (status === "accepted") {
    const selectedDriver = drivers.find((item) => item.id === driverId);

    if (!selectedDriver) {
      return res.status(400).json({ error: "Debes enviar driverId válido para aceptar el viaje" });
    }

    if (ride.driver?.id && ride.driver.id !== driverId) {
      return res.status(409).json({ error: "Este viaje ya fue aceptado por otro conductor" });
    }

    if (!ride.driver?.id && !selectedDriver.available) {
      return res.status(409).json({ error: "El conductor no está disponible" });
    }

    if (!ride.driver?.id && selectedDriver.category !== ride.category) {
      return res.status(409).json({ error: "La categoría del conductor no coincide con el viaje" });
    }

    if (!ride.driver?.id) {
      selectedDriver.available = false;
      applyDriverRatingSummary(selectedDriver);
      ride.driver = {
        id: selectedDriver.id,
        name: selectedDriver.name,
        rating: selectedDriver.rating,
        ratingCount: selectedDriver.ratingCount || 0,
        vehicle: selectedDriver.vehicle,
        completedRides: selectedDriver.completedRides
      };
      ride.etaMin = etaMinutes(selectedDriver, ride.pickupPoint || cityCenter);
    }
  }

  if ((status === "driver_arriving" || status === "in_progress" || status === "completed") && !ride.driver?.id) {
    return res.status(409).json({ error: "Debes aceptar el viaje antes de avanzar su estado" });
  }

  if (ride.driver?.id && driverId && ride.driver.id !== driverId) {
    return res.status(409).json({ error: "Solo el chofer asignado puede actualizar este viaje" });
  }

  ride.status = status;
  if (status === "accepted") {
    ride.assignmentState = "assigned";
    ride.progress = Math.max(ride.progress, 0.08);
    appendTimeline(ride, `Conductor acepto el viaje${ride.driver?.name ? `: ${ride.driver.name}` : ""}`);
  }

  if (status === "driver_arriving") {
    ride.assignmentState = "assigned";
    ride.progress = Math.max(ride.progress, 0.18);
    appendTimeline(ride, "Conductor en camino");
  }

  if (status === "in_progress") {
    ride.assignmentState = "assigned";
    ride.progress = Math.max(ride.progress, 0.55);
    appendTimeline(ride, "Carga iniciada por conductor");
  }

  if (status === "completed") {
    ride.assignmentState = "completed";
    ride.progress = 1;
    ride.etaMin = 0;
    appendTimeline(ride, "Entrega completada por conductor");
    if (ride.driver) {
      const driver = drivers.find((item) => item.id === ride.driver.id);
      if (driver) {
        applyDriverRatingSummary(driver);
        driver.available = true;
        driver.completedRides += 1;
        ride.driver.rating = driver.rating;
        ride.driver.ratingCount = driver.ratingCount || 0;
      }
    }

    if (ride.driver?.id && !hasRideSettlementEntries(ride.driver.id, ride.id)) {
      const grossAmount = Number.isFinite(Number(ride.fareEstimate))
        ? Number(Number(ride.fareEstimate).toFixed(2))
        : 0;
      if (grossAmount > 0) {
        const commissionAmount = Number((grossAmount * DEFAULT_DRIVER_COMMISSION_RATE).toFixed(2));
        appendDriverLedgerEntry({
          driverId: ride.driver.id,
          rideId: ride.id,
          type: "earn",
          amount: grossAmount,
          description: `Ingreso bruto por viaje ${ride.id}`
        });
        appendDriverLedgerEntry({
          driverId: ride.driver.id,
          rideId: ride.id,
          type: "commission",
          amount: -Math.abs(commissionAmount),
          description: `Comision plataforma ${(DEFAULT_DRIVER_COMMISSION_RATE * 100).toFixed(0)}%`
        });
      }
    }
  }

  if (status === "cancelled") {
    ride.assignmentState = "cancelled";
    ride.progress = 0;
    appendTimeline(ride, "Viaje cancelado por conductor");
    if (ride.driver) {
      const driver = drivers.find((item) => item.id === ride.driver.id);
      if (driver) {
        driver.available = true;
      }
    }
  }

  broadcastRide(ride);
  broadcastDrivers();
  return res.json(serializeRide(ride));
});

app.post("/api/driver/rides/:id/customer-rating", (req, res) => {
  const ride = rides.get(req.params.id);
  const driverId = String(req.body?.driverId || "").trim();
  const scoreValue = Number(req.body?.score);
  const score = Number.isFinite(scoreValue) ? Math.round(scoreValue) : NaN;
  const comment = String(req.body?.comment || "").trim().slice(0, 500);
  const adminNotes = String(req.body?.adminNotes || "").trim().slice(0, 1000);
  const complaintTags = Array.isArray(req.body?.complaintTags)
    ? [...new Set(req.body.complaintTags.map((tag) => String(tag || "").trim().toLowerCase()).filter(Boolean))].slice(0, 8)
    : [];

  if (!ride) {
    return res.status(404).json({ error: "Solicitud de carga no encontrada" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "driver", actorId: driverId, actorLabel: "chofer" })) {
    return;
  }

  if (ride.status !== "completed") {
    return res.status(409).json({ error: "Solo puedes calificar clientes en viajes completados" });
  }

  if (!driverId || !ride.driver?.id || ride.driver.id !== driverId) {
    return res.status(403).json({ error: "Solo el chofer asignado puede calificar al cliente" });
  }

  if (!ride.customer?.id) {
    return res.status(409).json({ error: "Este viaje no tiene cliente vinculado" });
  }

  if (score < 1 || score > 5) {
    return res.status(400).json({ error: "score debe ser un entero de 1 a 5" });
  }

  const existing = customerRatings.find((entry) => entry.rideId === ride.id);
  if (existing || ride.driverRatedCustomer === true) {
    return res.status(409).json({ error: "Este cliente ya fue calificado en este viaje" });
  }

  const record = normalizeCustomerRatingRecord({
    id: uuidv4(),
    rideId: ride.id,
    customerId: ride.customer.id,
    driverId,
    score,
    comment,
    complaintTags,
    adminNotes,
    createdAt: new Date().toISOString()
  });

  if (!record) {
    return res.status(400).json({ error: "No se pudo registrar la calificacion al cliente" });
  }

  customerRatings = saveCustomerRatings([record, ...customerRatings]);
  ride.driverRatedCustomer = true;
  appendTimeline(ride, `Chofer califico al cliente con ${record.score} estrella(s)`);

  const customer = adminCustomers.find((item) => item.id === ride.customer.id);
  if (customer) {
    applyCustomerRatingSummary(customer);
    ride.customer = serializeRideCustomer(customer);
  }

  if (complaintTags.length > 0 || adminNotes.isNotEmpty) {
    appendAdminIncident({
      subjectType: "customer",
      subjectId: ride.customer.id,
      category: complaintTags[0] || "actitud_agresiva",
      severity: complaintTags.includes("riesgo_seguridad") ? "alta" : "media",
      title: `Queja de chofer sobre cliente (${ride.customer.fullName})`,
      details: [
        complaintTags.length ? `Etiquetas: ${complaintTags.join(", ")}` : null,
        comment.isNotEmpty ? `Comentario chofer: ${comment}` : null,
        adminNotes.isNotEmpty ? `Notas privadas: ${adminNotes}` : null
      ].filter(Boolean).join(" | "),
      reportedBy: `driver:${driverId}`,
      rideId: ride.id,
      status: "open"
    });
  }

  broadcastRide(ride);

  return res.status(201).json({
    ok: true,
    ride: serializeRide(ride),
    rating: {
      id: record.id,
      rideId: record.rideId,
      customerId: record.customerId,
      driverId: record.driverId,
      score: record.score,
      comment: record.comment,
      createdAt: record.createdAt
    }
  });
});

app.post("/api/driver/incidents", (req, res) => {
  const driverId = String(req.body?.driverId || "").trim();
  const subjectType = String(req.body?.subjectType || "").trim().toLowerCase();
  const subjectId = String(req.body?.subjectId || "").trim();
  const category = String(req.body?.category || "").trim().toLowerCase();
  const severity = String(req.body?.severity || "media").trim().toLowerCase();
  const title = String(req.body?.title || "").trim();
  const details = String(req.body?.details || "").trim();
  const rideId = String(req.body?.rideId || "").trim();

  if (!driverId) {
    return res.status(400).json({ error: "driverId es requerido" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "driver", actorId: driverId, actorLabel: "chofer" })) {
    return;
  }
  if (!subjectType || !subjectId || !category || !title) {
    return res.status(400).json({ error: "subjectType, subjectId, category y title son requeridos" });
  }

  const record = appendAdminIncident({
    subjectType,
    subjectId,
    category,
    severity,
    title,
    details,
    rideId,
    reportedBy: `driver:${driverId}`,
    status: "open"
  });

  if (!record) {
    return res.status(400).json({ error: "No se pudo registrar incidencia" });
  }

  return res.status(201).json({ ok: true, incident: record });
});

app.post("/api/rides/:id/rating", (req, res) => {
  const ride = rides.get(req.params.id);
  if (!ride) {
    return res.status(404).json({ error: "Solicitud de carga no encontrada" });
  }

  if (ride.status !== "completed") {
    return res.status(409).json({ error: "Solo puedes calificar viajes completados" });
  }

  if (!ride.driver?.id) {
    return res.status(409).json({ error: "Este viaje no tiene conductor asignado" });
  }

  if (!enforceSelfOrAdmin(req, res, { role: "customer", actorId: ride.customer?.id, actorLabel: "cliente" })) {
    return;
  }

  const existing = driverRatings.find((entry) => entry.rideId === ride.id);
  if (existing || ride.riderRating) {
    return res.status(409).json({ error: "Este viaje ya fue calificado" });
  }

  const scoreValue = Number(req.body?.score);
  const score = Number.isFinite(scoreValue) ? Math.round(scoreValue) : NaN;
  if (score < 1 || score > 5) {
    return res.status(400).json({ error: "score debe ser un entero de 1 a 5" });
  }

  const comment = String(req.body?.comment || "").trim().slice(0, 500);
  const record = normalizeDriverRatingRecord({
    id: uuidv4(),
    rideId: ride.id,
    driverId: ride.driver.id,
    score,
    comment,
    createdAt: new Date().toISOString()
  });

  if (!record) {
    return res.status(400).json({ error: "No se pudo registrar la calificacion" });
  }

  driverRatings = saveDriverRatings([record, ...driverRatings]);
  ride.riderRating = {
    score: record.score,
    comment: record.comment,
    createdAt: record.createdAt
  };
  appendTimeline(ride, `Cliente califico al conductor con ${record.score} estrella(s)`);

  const driver = drivers.find((item) => item.id === ride.driver.id);
  if (driver) {
    applyDriverRatingSummary(driver);
    ride.driver.rating = driver.rating;
    ride.driver.ratingCount = driver.ratingCount || 0;
  }

  broadcastRide(ride);
  broadcastDrivers();

  return res.status(201).json({
    ok: true,
    ride: serializeRide(ride),
    rating: record,
    driver: driver || null
  });
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

setInterval(() => {
  for (const ride of rides.values()) {
    if (ride.driver?.id) {
      continue;
    }
    if (ride.status !== "pending_driver") {
      continue;
    }
    if (!hasAvailableDriverForCategory(ride.category)) {
      continue;
    }

    ride.status = "searching";
    ride.assignmentState = "searching";
    appendTimeline(ride, "Se detecto un chofer disponible. Reintentando asignacion ahora.");
    broadcastRide(ride);
  }
}, PENDING_RIDE_RETRY_INTERVAL_MS);

io.on("connection", (socket) => {
  socket.emit("drivers:update", drivers);

  socket.on("ride:watch", (rideId) => {
    const ride = rides.get(rideId);
    if (ride) {
      socket.emit("ride:update", serializeRide(ride));
    }
  });
});

app.get(/^\/(?!api\/).*/, (req, res, next) => {
  if (req.path.startsWith("/socket.io") || req.path.startsWith("/logo")) {
    return next();
  }

  if (!hasFlutterWebBuild) {
    return res.status(503).send(
      [
        "Frontend Flutter no encontrado.",
        "Ejecuta en la raiz del proyecto:",
        "npm run build:web:multi"
      ].join("\n")
    );
  }

  if (req.path.startsWith("/chofer") && fs.existsSync(FLUTTER_WEB_CHOFER_INDEX)) {
    return res.sendFile(FLUTTER_WEB_CHOFER_INDEX);
  }

  if (req.path.startsWith("/admin") && fs.existsSync(FLUTTER_WEB_ADMIN_INDEX)) {
    return res.sendFile(FLUTTER_WEB_ADMIN_INDEX);
  }

  return res.sendFile(FLUTTER_WEB_INDEX);
});

server.listen(PORT, () => {
  console.log(`Karryt Platform running on http://localhost:${PORT}`);
  console.log(`Frontend activo: ${hasFlutterWebBuild ? "Flutter Web" : "No compilado"}`);
  if (!hasFlutterWebBuild) {
    console.log("Compila Flutter Web multi-app con: npm run build:web:multi");
  }
  console.log(`\nCategorías disponibles:`);
  Object.values(vehicleCategories).forEach(cat => {
    console.log(`  - ${cat.label}: ${cat.capacity}`);
  });
});

