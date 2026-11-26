from django.contrib.auth import get_user_model
from django.db.models import Q
from rest_framework import serializers
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import BasePermission
from rest_framework.pagination import PageNumberPagination
from rest_framework.response import Response
from .models import Profile, Medicine, Report

User = get_user_model()

class PlatformAdmin(BasePermission):
    def has_permission(self, request, view):
        u = request.user
        return bool(u.is_authenticated and u.is_active and u.is_staff and u.is_superuser)

class Decision(serializers.Serializer):
    verified = serializers.BooleanField()

class AccountStatus(serializers.Serializer):
    active = serializers.BooleanField()

def page(request, rows):
    p = PageNumberPagination()
    p.page_size = 20
    return p.get_paginated_response(list(p.paginate_queryset(rows, request)))

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def overview(request):
    return Response(dict(username=request.user.username,
        users=User.objects.count(), medicines=Medicine.objects.count(),
        pending=Application.objects.filter(status='pending', profile__user__is_active=True).count(),
        verified=Application.objects.filter(status='approved', profile__professional_verified=True, profile__user__is_active=True).count(),
        reports=Report.objects.count()))

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def professionals(request):
    q = request.query_params.get('q', '').strip()
    rows = Profile.objects.filter(Q(professional_requested=True) | Q(professional_verified=True)).filter(
        Q(user__username__icontains=q) | Q(user__email__icontains=q) |
        Q(application__full_name__icontains=q) | Q(application__registration_number__icontains=q))
    status = request.query_params.get('status', '')
    if status == 'pending':
        rows = rows.filter(application__status='pending', user__is_active=True)
    elif status == 'verified':
        rows = rows.filter(application__status='approved', professional_verified=True, user__is_active=True)
    elif status == 'revoked':
        rows = rows.filter(Q(application__status='revoked') | Q(application__status='approved', professional_verified=False))
    elif status == 'rejected':
        rows = rows.filter(application__status='rejected')
    elif status == 'incomplete':
        rows = rows.filter(application__isnull=True)
    paginator = PageNumberPagination()
    paginator.page_size = 20
    fields = ['full_name','profession','registration_number','issuer','institution','location','phone','submitted_at','reason']
    selected = paginator.paginate_queryset(rows.order_by('id').values('id','user__username','user__email','user__is_active','professional_verified','application__status', *['application__'+f for f in fields]), request)
    results = []
    for row in selected:
        state = row.pop('application__status') or 'incomplete'
        if state == 'approved' and not row['professional_verified']:
            state = 'revoked'
        row['application_status'] = state
        row['professional_verified'] = bool(state == 'approved' and row['user__is_active'])
        for f in fields:
            row[f] = row.pop('application__'+f)
        results.append(row)
    response = paginator.get_paginated_response(results)
    response['Cache-Control'] = 'no-store, private'
    return response

@api_view(['PATCH'])
@permission_classes([PlatformAdmin])
def verify_professional(request, pk):
    return decide(request, pk)

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def professional_proof(request, pk):
    return proof_response(pk)

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def users(request):
    q = request.query_params.get('q', '').strip()
    rows = User.objects.filter(Q(username__icontains=q) | Q(email__icontains=q))
    return page(request, rows.order_by('id').values('id', 'username', 'email', 'is_active', 'is_staff', 'is_superuser'))

@api_view(['PATCH'])
@permission_classes([PlatformAdmin])
def account_status(request, pk):
    s = AccountStatus(data=request.data)
    s.is_valid(raise_exception=True)
    from django.db import transaction
    from .review_service import sync_all
    with transaction.atomic():
        list(Profile.objects.select_for_update().filter(user_id=pk).values_list('pk', flat=True))
        updated = User.objects.filter(pk=pk, is_staff=False, is_superuser=False).update(is_active=s.validated_data['active'])
        if updated:
            transaction.on_commit(sync_all, robust=True)
    if not updated:
        return Response({'detail': 'Compte introuvable ou protégé.'}, status=404)
    return Response({'active': s.validated_data['active']})

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def medicines(request):
    q = request.query_params.get('q', '').strip()
    return page(request, Medicine.objects.filter(name__icontains=q).order_by('name', 'id').values('id', 'name', 'source', 'published', 'author__username'))

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def reports(request):
    q = request.query_params.get('q', '').strip()
    return page(request, Report.objects.filter(medicine__icontains=q).order_by('-created', '-id').values('id', 'medicine', 'kind', 'details', 'created', 'user__username'))

from .models import ProfessionalApplication as Application
from .professional_api import decide, proof_response
