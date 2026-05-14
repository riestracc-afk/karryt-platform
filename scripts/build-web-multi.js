const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const rootDir = process.cwd();
const flutterDir = path.join(rootDir, "flutter_app");
const buildDir = path.join(flutterDir, "build");
const outUser = path.join(buildDir, "web_user");
const outDriver = path.join(buildDir, "web_driver");
const outAdmin = path.join(buildDir, "web_admin");
const outHosting = path.join(buildDir, "hosting");

function run(command, cwd = rootDir) {
  execSync(command, { cwd, stdio: "inherit" });
}

function resetDir(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
}

function copyDir(from, to) {
  fs.mkdirSync(to, { recursive: true });
  fs.cpSync(from, to, { recursive: true });
}

function customizeWebOutput(outputDir, options) {
  const {
    title,
    shortName,
    description,
    themeColor,
    backgroundColor,
    faviconFile,
    faviconLabel,
  } = options;

  const indexPath = path.join(outputDir, "index.html");
  const manifestPath = path.join(outputDir, "manifest.json");
  const faviconPath = path.join(outputDir, faviconFile);

  if (fs.existsSync(indexPath)) {
    let indexHtml = fs.readFileSync(indexPath, "utf8");
    indexHtml = indexHtml.replace(
      /<meta name="apple-mobile-web-app-title" content="[^"]*">/,
      `<meta name="apple-mobile-web-app-title" content="${title}">`
    );
    indexHtml = indexHtml.replace(/<title>[^<]*<\/title>/, `<title>${title}</title>`);
    indexHtml = indexHtml.replace(
      /<link rel="icon"[^>]*>/,
      `<link rel="icon" type="image/svg+xml" href="${faviconFile}"/>`
    );

    if (/<meta name="theme-color" content="[^"]*">/.test(indexHtml)) {
      indexHtml = indexHtml.replace(
        /<meta name="theme-color" content="[^"]*">/,
        `<meta name="theme-color" content="${themeColor}">`
      );
    } else {
      indexHtml = indexHtml.replace(
        "</head>",
        `  <meta name="theme-color" content="${themeColor}">\n</head>`
      );
    }

    fs.writeFileSync(indexPath, indexHtml, "utf8");
  }

  if (fs.existsSync(manifestPath)) {
    let manifest;
    const manifestRaw = fs.readFileSync(manifestPath, "utf8");
    try {
      manifest = JSON.parse(manifestRaw);
    } catch (error) {
      console.warn(`Manifest invalido en ${manifestPath}. Se regenera con valores por defecto: ${error.message}`);
      manifest = {
        name: title,
        short_name: shortName,
        start_url: ".",
        display: "standalone",
        background_color: backgroundColor,
        theme_color: themeColor,
        description,
        orientation: "portrait-primary",
        prefer_related_applications: false,
        icons: []
      };
    }
    manifest.name = title;
    manifest.short_name = shortName;
    manifest.description = description;
    manifest.theme_color = themeColor;
    manifest.background_color = backgroundColor;
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2), "utf8");
  }

  const faviconSvg = [
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">',
    `  <rect width="64" height="64" rx="14" fill="${themeColor}"/>`,
    `  <text x="32" y="40" font-size="28" text-anchor="middle" fill="#FFFFFF" font-family="Arial, sans-serif" font-weight="700">${faviconLabel}</text>`,
    '</svg>'
  ].join("\n");
  fs.writeFileSync(faviconPath, faviconSvg, "utf8");
}

console.log("==> Preparando build web multi-app de Karryt");
run("flutter pub get", flutterDir);

console.log("==> Build app Usuario (raiz)");
run("flutter build web -t lib/main_user.dart --base-href / --output build/web_user", flutterDir);

console.log("==> Build app Chofer (/chofer/)");
run("flutter build web -t lib/main_driver.dart --base-href /chofer/ --output build/web_driver", flutterDir);

console.log("==> Build app Admin PC (/admin/)");
run("flutter build web -t lib/main_admin.dart --base-href /admin/ --output build/web_admin", flutterDir);

console.log("==> Personalizando identidad visual por app");
customizeWebOutput(outUser, {
  title: "Karryt Usuario",
  shortName: "Karryt User",
  description: "App de usuario Karryt para solicitar viajes de carga",
  themeColor: "#14532D",
  backgroundColor: "#F3F6FB",
  faviconFile: "favicon-user.svg",
  faviconLabel: "U",
});
customizeWebOutput(outDriver, {
  title: "Karryt Chofer",
  shortName: "Karryt Driver",
  description: "App de chofer Karryt para aceptar y gestionar viajes",
  themeColor: "#1D4ED8",
  backgroundColor: "#F3F6FB",
  faviconFile: "favicon-driver.svg",
  faviconLabel: "C",
});
customizeWebOutput(outAdmin, {
  title: "Karryt Admin PC",
  shortName: "Karryt Admin",
  description: "Consola de administracion Karryt para monitoreo y control",
  themeColor: "#7C2D12",
  backgroundColor: "#F3F6FB",
  faviconFile: "favicon-admin.svg",
  faviconLabel: "A",
});

console.log("==> Empaquetando artefactos en flutter_app/build/hosting");
resetDir(outHosting);
copyDir(outUser, outHosting);
copyDir(outDriver, path.join(outHosting, "chofer"));
copyDir(outAdmin, path.join(outHosting, "admin"));

console.log("==> Build multi-app completado.");
