@echo off
cd /d "c:\Proyectos\Proyecto Karryt\flutter_app"
flutter run -d chrome -t lib/main_admin.dart --dart-define=API_BASE_URL=https://karryt-api-502814108153.us-central1.run.app --dart-define=KARRYT_ADMIN_ID=ADM-1000
