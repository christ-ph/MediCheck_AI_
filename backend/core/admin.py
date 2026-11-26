from django.contrib import admin
from .models import Profile, Medicine, Report
admin.site.register(Profile)
@admin.register(Medicine)
class MedicineAdmin(admin.ModelAdmin):
    list_display=('name','published','author')
    readonly_fields=('published',)

    def get_readonly_fields(self, request, obj=None):
        if obj and obj.review_cycles.exists():
            return ('name', 'description', 'source', 'published', 'author')
        return super().get_readonly_fields(request, obj)
admin.site.register(Report)
