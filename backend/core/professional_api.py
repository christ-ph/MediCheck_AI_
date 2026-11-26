from django.db import transaction
from django.http import HttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import serializers
from rest_framework.decorators import api_view, permission_classes, parser_classes
from rest_framework.parsers import MultiPartParser, FormParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.response import Response
from .models import Profile, ProfessionalApplication as Application


class ApplicationSerializer(serializers.Serializer):
    full_name = serializers.CharField(max_length=180, min_length=3)
    profession = serializers.CharField(max_length=100, min_length=2)
    registration_number = serializers.CharField(max_length=100, min_length=2)
    issuer = serializers.CharField(max_length=180, min_length=2)
    institution = serializers.CharField(max_length=180, min_length=2)
    location = serializers.CharField(max_length=180, min_length=2)
    phone = serializers.RegexField(regex=r'^\+?[0-9 ()-]{7,40}$')
    proof = serializers.FileField()

    def validate_proof(self, file):
        if not 0 < file.size <= 5 * 1024 * 1024:
            raise serializers.ValidationError('Justificatif limité à 5 Mo.')
        header = file.read(8)
        file.seek(0)
        if header.startswith(b'%PDF-'):
            kind = 'application/pdf'
        elif header.startswith(b'\xff\xd8\xff'):
            kind = 'image/jpeg'
        elif header == b'\x89PNG\r\n\x1a\n':
            kind = 'image/png'
        else:
            raise serializers.ValidationError('Format accepté : PDF, JPG ou PNG.')
        return (file.read(), kind)


def profile_info(user):
    profile, _ = Profile.objects.get_or_create(user=user)
    row = Application.objects.filter(profile=profile).values('status', 'reason').first()
    verified = bool(user.is_active and profile.professional_verified and row and row['status'] == Application.Status.APPROVED)
    status = row['status'] if row else ('incomplete' if profile.professional_requested or profile.professional_verified else 'none')
    if status == Application.Status.APPROVED and not verified:
        status = Application.Status.REVOKED
    from .models import ReviewNotification
    unread = ReviewNotification.objects.filter(user=user, read_at__isnull=True).count()
    return dict(notification_unread=unread, review_unread=unread, username=user.username, professional_requested=profile.professional_requested,
                professional_verified=verified, professional_status=status,
                reason=row['reason'] if row else '')


@api_view(['POST'])
@permission_classes([IsAuthenticated])
@parser_classes([MultiPartParser, FormParser])
def apply_professional(request):
    serializer = ApplicationSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    data = dict(serializer.validated_data)
    proof, proof_type = data.pop('proof')
    with transaction.atomic():
        profile, _ = Profile.objects.get_or_create(user=request.user)
        profile = Profile.objects.select_for_update().get(pk=profile.pk)
        existing = Application.objects.filter(profile=profile).values('status').first()
        if existing and (existing['status'] == Application.Status.PENDING or (existing['status'] == Application.Status.APPROVED and profile.professional_verified)):
            raise ValidationError('Un dossier est déjà en attente ou validé.')
        Application.objects.update_or_create(profile=profile, defaults={**data, 'proof': proof, 'proof_type': proof_type,
            'status': Application.Status.PENDING, 'reason': '', 'reviewed_at': None, 'reviewed_by': None})
        profile.professional_requested = True
        profile.professional_verified = False
        profile.save(update_fields=['professional_requested', 'professional_verified'])
    return Response(profile_info(request.user), status=201)


def decide(request, pk):
    class Decision(serializers.Serializer):
        verified = serializers.BooleanField()
        reason = serializers.CharField(max_length=500, required=False, allow_blank=True)
    s = Decision(data=request.data)
    s.is_valid(raise_exception=True)
    verified = s.validated_data['verified']
    reason = s.validated_data.get('reason', '').strip()
    with transaction.atomic():
        profile = get_object_or_404(Profile.objects.select_for_update(), pk=pk, professional_requested=True)
        app = Application.objects.filter(profile=profile).defer('proof').first()
        if not app:
            raise ValidationError('Dossier incomplet : le professionnel doit soumettre un justificatif.')
        if verified:
            if not profile.user.is_active or app.status != Application.Status.PENDING:
                raise ValidationError('Seul un dossier en attente associé à un compte actif peut être validé.')
            app.status = Application.Status.APPROVED
            reason = ''
        else:
            if not reason:
                raise ValidationError('Motif obligatoire pour un refus ou une révocation.')
            if app.status == Application.Status.PENDING:
                app.status = Application.Status.REJECTED
            elif app.status == Application.Status.APPROVED:
                app.status = Application.Status.REVOKED
            else:
                raise ValidationError('Ce dossier a déjà été traité.')
        app.reason = reason
        app.reviewed_by = request.user
        app.reviewed_at = timezone.now()
        app.save(update_fields=['status', 'reason', 'reviewed_by', 'reviewed_at'])
        profile.professional_verified = verified
        profile.save(update_fields=['professional_verified'])
        from .models import ReviewNotification
        messages = {'approved':'Votre dossier professionnel a été accepté. Vous pouvez désormais contribuer au catalogue.', 'rejected':'Votre dossier professionnel a été refusé. Consultez le motif dans votre compte.', 'revoked':'Votre validation professionnelle a été retirée. Consultez votre compte.'}
        ReviewNotification.objects.create(user_id=profile.user_id, category='professional', message=messages[app.status])
    from .review_service import sync_all
    transaction.on_commit(sync_all, robust=True)
    return Response({'verified': verified, 'status': app.status})


def proof_response(pk):
    app = get_object_or_404(Application, profile_id=pk)
    ext = {'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png'}[app.proof_type]
    response = HttpResponse(bytes(app.proof), content_type='application/octet-stream')
    response['Content-Disposition'] = f'attachment; filename="justificatif-{pk}.{ext}"'
    response['Cache-Control'] = 'no-store, private'
    response['X-Content-Type-Options'] = 'nosniff'
    return response
