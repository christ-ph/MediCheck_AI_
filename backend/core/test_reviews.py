from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase
from .models import Profile, ProfessionalApplication, Medicine, ReviewCycle, ReviewAssignment, ReviewNotification, PointWallet, PointTransaction
from .review_service import sync_all


class ReviewTests(APITestCase):
    def pro(self,name):
        u=get_user_model().objects.create_user(username=name)
        p=Profile.objects.create(user=u,professional_requested=True,professional_verified=True)
        ProfessionalApplication.objects.create(profile=p,status='approved',proof=b'%PDF-test')
        return u

    def setUp(self):
        self.author=self.pro('author-review')
        self.reviewers=[self.pro(f'reviewer-{i}') for i in range(5)]
        self.ordinary=get_user_model().objects.create_user(username='ordinary-review')
        self.admin=get_user_model().objects.create_superuser(username='admin-review',password='test-pass-123')
        self.data=dict(name='Médicament fictif 10 mg',description='Fiche fictive exclusivement destinée aux tests.',source='https://example.org/test')
        self.vote_data=dict(decision='approve',comment='Examen fictif complet de la source et de la fiche.',source_checked=True,identity_checked=True,content_checked=True)

    def submit(self):
        self.client.force_authenticate(self.author)
        r=self.client.post('/api/proposals/',self.data,format='json'); self.assertEqual(r.status_code,201,r.data)
        return ReviewCycle.objects.get(medicine_id=r.data['id'])

    def vote(self,a,decision='approve'):
        self.client.force_authenticate(a.reviewer)
        return self.client.post(f'/api/reviews/inbox/{a.pk}/vote/',{**self.vote_data,'decision':decision},format='json')

    def test_unanimous_and_points_and_permissions(self):
        c=self.submit(); self.assertEqual(c.status,'reviewing'); self.assertEqual(c.assignments.count(),5)
        self.assertFalse(c.assignments.filter(reviewer=self.author).exists()); self.assertEqual(ReviewNotification.objects.filter(cycle=c,user__in=self.reviewers).count(),5)
        a=c.assignments.first(); self.client.force_authenticate(self.author)
        self.assertEqual(self.client.post(f'/api/reviews/inbox/{a.pk}/vote/',self.vote_data,format='json').status_code,404)
        self.client.force_authenticate(self.ordinary); self.assertEqual(self.client.get('/api/reviews/inbox/').status_code,403)
        self.assertEqual(self.client.get('/api/admin/reviews/').status_code,403)
        for i,a in enumerate(c.assignments.all()):
            self.assertEqual(self.vote(a).status_code,200)
            self.assertEqual(Medicine.objects.get(pk=c.medicine_id).published,i==4)
            self.assertEqual(self.vote(a).status_code,409)
        self.assertEqual(PointWallet.objects.get(user=self.author).balance,50)
        self.assertEqual(PointTransaction.objects.count(),6)
        self.assertTrue(all(PointWallet.objects.get(user=u).balance==10 for u in self.reviewers))
        sync_all(); self.assertEqual(PointTransaction.objects.count(),6)

    def test_reject_then_revision_no_double_reward(self):
        c=self.submit()
        for i,a in enumerate(c.assignments.all()): self.assertEqual(self.vote(a,'reject' if i==0 else 'approve').status_code,200)
        c.refresh_from_db(); self.assertEqual(c.status,'revision'); self.assertFalse(c.medicine.published)
        self.assertFalse(PointWallet.objects.filter(user=self.author).exists())
        self.client.force_authenticate(self.author)
        r=self.client.post(f'/api/reviews/mine/{c.pk}/revise/',{**self.data,'description':'Fiche fictive corrigée pour ce test.'},format='json'); self.assertEqual(r.status_code,201,r.data)
        c2=ReviewCycle.objects.get(pk=r.data['id']); self.assertEqual(c2.number,2)
        for a in c2.assignments.all(): self.assertEqual(self.vote(a).status_code,200)
        self.assertEqual(PointTransaction.objects.count(),6)
        self.assertEqual(PointWallet.objects.get(user=self.author).balance,50)

    def test_waiting_and_revocation(self):
        p=self.reviewers[-1].profile; p.professional_verified=False; p.save()
        c=self.submit(); self.assertEqual(c.status,'waiting'); self.assertEqual(c.assignments.count(),0)
        p.professional_verified=True; p.save(); sync_all(); c.refresh_from_db(); self.assertEqual(c.status,'reviewing')
        a=c.assignments.first(); p=a.reviewer.profile; p.professional_verified=False; p.save()
        extra=self.pro('replacement-reviewer'); sync_all(); a.refresh_from_db()
        self.assertEqual(a.state,'cancelled'); self.assertTrue(c.assignments.filter(reviewer=extra,state='pending').exists())
        self.assertEqual(self.vote(a).status_code,403)

    def test_import_pending_and_notification_privacy(self):
        m=Medicine.objects.create(**self.data,author=self.author,published=False); sync_all(); sync_all(); c=ReviewCycle.objects.get(medicine=m)
        n=ReviewNotification.objects.filter(cycle=c,user=self.reviewers[0]).first()
        self.client.force_authenticate(self.ordinary); self.assertEqual(self.client.get('/api/reviews/notifications/').data['count'],0)
        self.client.post(f'/api/reviews/notifications/{n.pk}/read/',{},format='json'); n.refresh_from_db(); self.assertIsNone(n.read_at)
