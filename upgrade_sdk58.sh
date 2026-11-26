#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/mobile"

echo "=========================================="
echo " MEDICHECK AI - MIGRATION EXPO SDK 58"
echo "=========================================="

trap 'echo "Migration interrompue. Consultez les erreurs ci-dessus."' ERR

# Charger NVM si disponible

export NVM_DIR="$HOME/.nvm"

if [ -s "$NVM_DIR/nvm.sh" ]; then
    source "$NVM_DIR/nvm.sh"
    nvm use 22
fi

# Vérifier Node.js

node -e '
const [major, minor] = process.versions.node.split(".").map(Number);

if (
    !(major === 22 && minor >= 13) &&
    !(major === 24 && minor >= 3) &&
    major < 26
) {
    console.error("Version Node.js incompatible.");
    console.error("Installez Node.js 22.13 ou supérieur sur la branche 22.");
    process.exit(1);
}
'

echo "Node.js : $(node -v)"
echo "npm     : $(npm -v)"

# Vérifier les fichiers

if [ ! -f package.json ]; then
    echo "package.json introuvable."
    exit 1
fi

# Sauvegarde complète du frontend mobile

BACKUP="../mobile-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

tar \
    --exclude=node_modules \
    --exclude=.expo \
    --exclude=dist \
    --exclude=.git \
    -czf "$BACKUP" .

echo "Sauvegarde : $BACKUP"

# Retirer les anciennes options incompatibles

node <<'JS'
const fs = require('fs');

if (fs.existsSync('app.json')) {
    const config = JSON.parse(
        fs.readFileSync('app.json', 'utf8')
    );

    if (config.expo) {
        delete config.expo.sdkVersion;
        delete config.expo.newArchEnabled;
    }

    fs.writeFileSync(
        'app.json',
        JSON.stringify(config, null, 2) + '\n'
    );
}
JS

# Identifier la version actuelle

CURRENT=$(node -p '
require("./package.json")
    .dependencies.expo.match(/\d+/)[0]
')

echo "SDK actuel : $CURRENT"

if [ "$CURRENT" -gt 58 ]; then
    echo "Le projet utilise déjà un SDK supérieur à 58."
    exit 1
fi

# Migration progressive

for SDK in 55 56 57 58
do
    if [ "$SDK" -le "$CURRENT" ]; then
        continue
    fi

    echo ""
    echo "=========================================="
    echo " MIGRATION VERS EXPO SDK $SDK"
    echo "=========================================="

    npm install "expo@^${SDK}.0.0"

    npx expo install --fix

    echo "SDK $SDK : dépendances mises à jour."
done

# Réinstaller les modules utilisés par MediCheck
# dans leurs versions compatibles avec SDK 58.

npx expo install \
    react \
    react-dom \
    react-native \
    react-native-web \
    expo-camera \
    expo-image-picker \
    expo-document-picker \
    expo-secure-store

# Vérification des dépendances

npx expo install --fix

# Nettoyage du cache local Expo

rm -rf .expo

# Afficher les versions finales

echo ""
echo "=========================================="
echo " VERSIONS FINALES"
echo "=========================================="

npm list --depth=0

# Diagnostic final

npx --yes expo-doctor@latest

echo ""
echo "=========================================="
echo " MIGRATION DES DEPENDANCES TERMINEE"
echo "=========================================="

echo "Lancement :"
echo "cd ~/Bureau/MediCheck/mobile"
echo "npx expo start --lan --clear"

