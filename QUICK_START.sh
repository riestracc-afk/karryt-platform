#!/bin/bash
# KARRIT Platform - Quick Setup Script
# Este script te guía a través de la configuración en orden

echo "🚀 KARRIT Platform - Firebase + GitHub Setup"
echo "=============================================="
echo ""

echo "✅ Lo que YA está hecho:"
echo "   • Backend preparado para Firestore"
echo "   • GitHub Actions workflow creado"
echo "   • Repositorio Git inicializado"
echo "   • Primer commit listo"
echo ""

echo "📋 Ahora DEBES hacer esto (en orden):"
echo ""

echo "1️⃣  Crear proyecto Firebase:"
echo "   👉 https://console.firebase.google.com"
echo "   • Nuevo Proyecto"
echo "   • Nombre: karrit-platform"
echo "   • Crear"
echo ""

echo "2️⃣  Obtener credenciales de Firebase:"
echo "   👉 Firebase Console → Configuración (engranaje) → Cuentas de Servicio"
echo "   • Generar nueva clave privada"
echo "   • Descargar JSON"
echo "   • Guardar en lugar seguro"
echo ""

echo "3️⃣  Crear repositorio en GitHub:"
echo "   👉 https://github.com/new"
echo "   • Repository name: karrit-platform"
echo "   • Description: KARRIT - Plataforma de conexión para transporte de carga"
echo "   • Public"
echo "   • Crear"
echo ""

echo "4️⃣  Conectar Git (ejecutar en PowerShell):"
echo "   git remote add origin https://github.com/TU_USUARIO/karrit-platform.git"
echo "   git push -u origin main"
echo ""

echo "5️⃣  Configurar GitHub Secrets:"
echo "   👉 GitHub Repo → Settings → Secrets and variables → Actions"
echo "   • New Secret"
echo "   • Name: FIREBASE_SERVICE_ACCOUNT"
echo "   • Value: [pegar el JSON descargado]"
echo ""

echo "6️⃣  Crear .env local:"
echo "   • Copiar: .env.example → .env"
echo "   • Abrir .env"
echo "   • Llenar con datos del JSON"
echo ""

echo "🎉 Después, tu app estará en: https://karrit-platform.web.app"
echo ""
echo "¿Necesitas ayuda? Pregunta en GitHub Issues o aquí mismo."
