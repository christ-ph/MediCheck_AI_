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
        pending=Profile.objects.filter(professional_requested=True, professional_verified=False, user__is_active=True).count(),
        verified=Profile.objects.filter(professional_verified=True, user__is_active=True).count(),
        reports=Report.objects.count()))

@api_view(['GET'])
@permission_classes([PlatformAdmin])
def professionals(request):
    q = request.query_params.get('q', '').strip()
    rows = Profile.objects.filter(professional_requested=True).filter(Q(user__username__icontains=q) | Q(user__email__icontains=q))
    status = request.query_params.get('status', '')
    if status == 'pending':
        rows = rows.filter(professional_verified=False, user__is_active=True)
    elif status == 'verified':
        rows = rows.filter(professional_verified=True, user__is_active=True)
    return page(request, rows.order_by('id').values('id', 'user__username', 'user__email', 'user__is_active', 'professional_verified'))

@api_view(['PATCH'])
@permission_classes([PlatformAdmin])
def verify_professional(request, pk):
    s = Decision(data=request.data)
    s.is_valid(raise_exception=True)
    value = s.validated_data['verified']
    rows = Profile.objects.filter(pk=pk, professional_requested=True)
    if value:
        rows = rows.filter(user__is_active=True)
    if not rows.update(professional_verified=value):
        return Response({'detail': 'Profil introuvable ou inactif.'}, status=404)
    return Response({'verified': value})

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
    updated = User.objects.filter(pk=pk, is_staff=False, is_superuser=False).update(is_active=s.validated_data['active'])
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
