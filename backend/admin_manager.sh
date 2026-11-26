#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f manage.py ]; then
    echo "Erreur : manage.py introuvable."
    exit 1
fi

uv run python -c "$(cat <<'PY'

import os
import getpass

os.environ.setdefault(
    'DJANGO_SETTINGS_MODULE',
    'config.settings'
)

import django
django.setup()

from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from core.models import Profile, Medicine, Report

User = get_user_model()


# ==========================================
# CREATION OU PROMOTION ADMINISTRATEUR
# ==========================================

def create_admin():

    print("\n=== CONFIGURATION ADMINISTRATEUR ===")

    username = input("Nom utilisateur : ").strip()

    if not username:
        print("Identifiant obligatoire.")
        return

    user = User.objects.filter(
        username=username
    ).first()

    if user:

        if not user.is_active:
            print("Ce compte est désactivé.")
            return

        if user.is_superuser and user.is_staff:
            print("Ce compte est déjà administrateur.")
            return

        password = getpass.getpass(
            "Mot de passe actuel du compte : "
        )

        if not user.check_password(password):
            print("Mot de passe incorrect.")
            return

        confirm = input(
            "Promouvoir ce compte administrateur ? (o/n) : "
        )

        if confirm.lower() != "o":
            print("Opération annulée.")
            return

        user.is_staff = True
        user.is_superuser = True

        user.save(
            update_fields=[
                "is_staff",
                "is_superuser"
            ]
        )

        print("Compte promu administrateur.")

    else:

        email = input("Adresse email : ").strip()

        password = getpass.getpass(
            "Mot de passe : "
        )

        confirmation = getpass.getpass(
            "Confirmer le mot de passe : "
        )

        if password != confirmation:
            print("Les mots de passe sont différents.")
            return

        try:
            validate_password(
                password,
                User(username=username, email=email)
            )

        except ValidationError as error:

            for message in error.messages:
                print(message)

            return

        User.objects.create_superuser(
            username=username,
            email=email,
            password=password
        )

        print("Administrateur créé avec succès.")


# ==========================================
# AUTHENTIFICATION ADMINISTRATEUR
# ==========================================

def authenticate_admin():

    username = input(
        "Identifiant administrateur : "
    ).strip()

    password = getpass.getpass(
        "Mot de passe administrateur : "
    )

    user = User.objects.filter(
        username=username,
        is_active=True,
        is_staff=True,
        is_superuser=True
    ).first()

    if user and user.check_password(password):
        return user

    print("Accès refusé.")
    return None


# ==========================================
# LISTE DES PROFESSIONNELS
# ==========================================

def list_professionals():

    profiles = Profile.objects.filter(
        professional_requested=True
    ).select_related("user").order_by("id")

    print("\n=== PROFESSIONNELS DE SANTE ===")

    if not profiles.exists():
        print("Aucune demande professionnelle.")
        return

    print("-" * 80)

    for profile in profiles:

        status = (
            "VALIDE"
            if profile.professional_verified
            else "EN ATTENTE"
        )

        print(
            f"ID : {profile.id} | "
            f"Utilisateur : {profile.user.username} | "
            f"Email : {profile.user.email} | "
            f"Statut : {status}"
        )

    print("-" * 80)


# ==========================================
# DEMANDES EN ATTENTE
# ==========================================

def pending_professionals():

    profiles = Profile.objects.filter(
        professional_requested=True,
        professional_verified=False,
        user__is_active=True
    ).select_related("user")

    print("\n=== DEMANDES EN ATTENTE ===")

    if not profiles.exists():

        print("Aucune demande en attente.")
        return

    for profile in profiles:

        print(
            f"ID : {profile.id} | "
            f"Utilisateur : {profile.user.username} | "
            f"Email : {profile.user.email}"
        )


# ==========================================
# VALIDATION PROFESSIONNEL
# ==========================================

def validate_professional(admin):

    pending_professionals()

    profile_id = input(
        "\nID du profil à valider : "
    ).strip()

    if not profile_id.isdigit():
        print("Identifiant invalide.")
        return

    profile = Profile.objects.filter(
        id=int(profile_id),
        professional_requested=True,
        professional_verified=False,
        user__is_active=True
    ).select_related("user").first()

    if not profile:
        print("Aucune demande en attente correspondante.")
        return

    print("\nInformations du professionnel :")
    print("Utilisateur :", profile.user.username)
    print("Email :", profile.user.email)

    confirm = input(
        "Justificatifs professionnels vérifiés ? "
        "Confirmer la validation (o/n) : "
    )

    if confirm.lower() == "o":

        profile.professional_verified = True

        profile.save(
            update_fields=["professional_verified"]
        )

        print("Professionnel validé avec succès.")
        print("Validation effectuée par :", admin.username)

    else:

        print("Validation annulée.")


# ==========================================
# RETIRER UNE VALIDATION
# ==========================================

def revoke_professional():

    list_professionals()

    profile_id = input(
        "\nID du profil à révoquer : "
    ).strip()

    if not profile_id.isdigit():
        print("Identifiant invalide.")
        return

    profile = Profile.objects.filter(
        id=int(profile_id),
        professional_verified=True
    ).first()

    if not profile:
        print("Profil professionnel validé introuvable.")
        return

    confirm = input(
        f"Retirer la validation de "
        f"{profile.user.username} ? (o/n) : "
    )

    if confirm.lower() != "o":
        print("Opération annulée.")
        return

    profile.professional_verified = False

    profile.save(
        update_fields=["professional_verified"]
    )

    print("Validation professionnelle retirée.")


# ==========================================
# STATISTIQUES
# ==========================================

def statistics():

    print("\n=== STATISTIQUES MEDICHECK AI ===")

    print(
        "Nombre utilisateurs :",
        User.objects.count()
    )

    print(
        "Administrateurs :",
        User.objects.filter(
            is_superuser=True,
            is_active=True
        ).count()
    )

    print(
        "Professionnels validés :",
        Profile.objects.filter(
            professional_verified=True
        ).count()
    )

    print(
        "Demandes en attente :",
        Profile.objects.filter(
            professional_requested=True,
            professional_verified=False
        ).count()
    )

    print(
        "Médicaments :",
        Medicine.objects.count()
    )

    print(
        "Médicaments publiés :",
        Medicine.objects.filter(
            published=True
        ).count()
    )

    print(
        "Signalements :",
        Report.objects.count()
    )


# ==========================================
# MENU ADMINISTRATEUR
# ==========================================

def admin_menu(admin):

    while True:

        print("\n" + "=" * 50)
        print("       MEDICHECK AI - ADMINISTRATION")
        print("=" * 50)

        print("Connecté :", admin.username)

        print("1. Lister les professionnels")
        print("2. Voir les demandes en attente")
        print("3. Valider un professionnel")
        print("4. Retirer une validation")
        print("5. Consulter les statistiques")
        print("0. Se déconnecter")

        choice = input("\nVotre choix : ").strip()

        if choice == "1":

            list_professionals()

        elif choice == "2":

            pending_professionals()

        elif choice == "3":

            validate_professional(admin)

        elif choice == "4":

            revoke_professional()

        elif choice == "5":

            statistics()

        elif choice == "0":

            break

        else:

            print("Choix invalide.")


# ==========================================
# PROGRAMME PRINCIPAL
# ==========================================

while True:

    print("\n" + "=" * 50)
    print("           MEDICHECK AI")
    print("       ADMINISTRATION SYSTEME")
    print("=" * 50)

    print("1. Créer ou promouvoir un administrateur")
    print("2. Se connecter comme administrateur")
    print("0. Quitter")

    choice = input("\nVotre choix : ").strip()

    if choice == "1":

        create_admin()

    elif choice == "2":

        admin = authenticate_admin()

        if admin:
            admin_menu(admin)

    elif choice == "0":

        print("Fermeture du programme.")
        break

    else:

        print("Choix invalide.")

PY
)"
