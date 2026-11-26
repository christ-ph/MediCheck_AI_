# MediCheck AI — Sprint 1 / prototype
## Backend
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python manage.py makemigrations core
python manage.py migrate
python manage.py createsuperuser
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1,10.0.2.2 python manage.py runserver 0.0.0.0:8000
## Mobile (autre terminal)
Node 20.19.4+ recommandé. cd mobile ; npm install ; npx expo start.
Pour un téléphone physique, créer mobile/.env avec EXPO_PUBLIC_API_URL=http://IP_DU_PC:8000 et ajouter cette IP à DJANGO_ALLOWED_HOSTS. Même réseau Wi-Fi. Pour le navigateur: npm run web.
## Périmètre
Inscription, JWT, demande de profil professionnel, administration, catalogue en lecture, propositions non publiées et signalements. Validation collaborative à cinq, OCR, IA, paiements, OTP et notifications non implémentés. Aucun médicament réel préchargé. Publication bloquée dans le back-office tant que le workflow de validation n'est pas développé. Illustration générique originale, pas une photographie de Doliprane. SQLite pour le développement; PostgreSQL et Docker à venir. Jeton conservé en mémoire uniquement. Ne pas déployer cette configuration de développement en production. Tests d'intégration et compilation Expo non exécutés.
